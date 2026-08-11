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
# bin/fm-timeout-lib.sh is the single owner of a bounded call, and it is what
# makes the probe cases below run on a host that ships no timeout(1).
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-timeout-lib.sh"

SERVER="$ROOT/bin/fm-dashboard-server.mjs"
INSTALLER="$ROOT/bin/fm-dashboard-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-access)
USER_EVENT_STORE_BEFORE=$(fm_user_event_store_snapshot)
SERVER_PID=
TEST_PORT=
PASSWORD='harbour-lantern-42'
# The trusted-proxy allowlist the next fixture server starts with. Empty is the
# shipped default and means no forwarded header is read at all.
TRUSTED_PROXIES=
# Node options the next installer run inherits, for the cases that need the
# probes the installer shells out to make noise on standard error.
INSTALLER_NODE_OPTIONS=

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
    NODE_OPTIONS="$INSTALLER_NODE_OPTIONS" \
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
    FM_DASHBOARD_TRUSTED_PROXIES="$TRUSTED_PROXIES" \
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

# A dashboard on the given bind address, waited for over loopback. A server that
# refused to start is the failure this reports, with its own log as the reason.
start_server_on() {  # <case-root> <address>
  local case_root=$1 address=$2 attempt
  TEST_PORT=$(free_port)
  mkdir -p "$case_root/home/data" "$case_root/home/state"
  FM_HOME="$case_root/home" \
    FM_DASHBOARD_ADDRESS="$address" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS=4 \
    FM_DASHBOARD_POLL_SECONDS=5 \
    FM_DASHBOARD_AUTH_FILE="$case_root/dashboard-auth.json" \
    FM_DASHBOARD_TRUSTED_PROXIES="$TRUSTED_PROXIES" \
    node "$SERVER" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ "$(status_for /api/snapshot)" != "000" ] && return 0
    sleep 0.1
  done
  fail "the dashboard bound to $address never answered on loopback: $(cat "$case_root/server.log")"
}

# Stand in for systemctl, so the installer's post-restart contract can be
# exercised without enabling or restarting anything on the developer's machine.
# The read-backs answer out of the unit the installer just wrote, which is what
# systemd does too; the liveness answers are the case under test.
write_systemctl_stub() {  # <bin-dir> <active-state> <restart-count>
  local bin_dir=$1 active_state=$2 restarts=$3
  mkdir -p "$bin_dir"
  cat > "$bin_dir/systemctl" <<EOF
#!/usr/bin/env bash
unit="\$XDG_CONFIG_HOME/systemd/user/firstmate-dashboard.service"
case "\$*" in
  *"-p EnvironmentFiles"*) sed -n 's/^EnvironmentFile=//p' "\$unit" ;;
  *"-p Environment"*) sed -n 's/^Environment=//p' "\$unit" ;;
  *"-p ReadWritePaths"*) sed -n 's/^ReadWritePaths=-//p' "\$unit" ;;
  *"-p RuntimeDirectory"*) sed -n 's/^RuntimeDirectory=//p' "\$unit" ;;
  *"-p DropInPaths"*) : ;;
  *"-p ActiveState"*) printf '%s\n' '$active_state' ;;
  *"-p NRestarts"*) printf '%s\n' '$restarts' ;;
  *status*) printf 'stub: %s\n' '$active_state'; [ '$active_state' = active ] || exit 3 ;;
  *) : ;;
esac
EOF
  chmod +x "$bin_dir/systemctl"
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

  # The unit emits one ReadWritePaths= line per grant, each carrying systemd's
  # optional "-" prefix, so every line is checked as its own absolute path and
  # the event directory has to be one of them. A membership check rather than an
  # equality check, because a second grant is not a defect and must not read as
  # the unit granting the wrong path.
  local granted grants pinned line
  grants=$(unit_directive "$unit" ReadWritePaths)
  [ -n "$grants" ] || fail "the unit has no ReadWritePaths directive"
  granted=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line=${line#-}
    case "$line" in
      /*) ;;
      *) fail "ReadWritePaths is not an absolute path: [$line]" ;;
    esac
    granted=$granted$line$'\n'
  done <<EOF
$grants
EOF
  pinned=$(sed -n 's/^FM_DASHBOARD_EVENT_DB="\(.*\)"$/\1/p' "$env_file")
  printf '%s' "$granted" | grep -qxF "${pinned%/*}" \
    || fail "the unit grants [$grants] while the service opens a store in [${pinned%/*}]"
  [ -d "${pinned%/*}" ] || fail "the granted event directory was not created: [${pinned%/*}]"

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

  # The abbreviated form of the same install: a permanent checkout named and
  # nothing else. The refusal above is only half the guard, because the unit
  # pins an operational home too and derives the event store from it - a home
  # left in the worktree hands the persistent service a fleet home and a store
  # that are about to be reclaimed, which is the breakage --checkout exists to
  # prevent arriving by the other pinned path.
  rm -f "$unit"
  local pinned_home
  env -u FM_DASHBOARD_EVENTS_CONFIG -u FM_DASHBOARD_AUTH_FILE -u FM_HOME \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" \
    "$case_root/scratch/bin/fm-dashboard-install.sh" \
    --checkout "$case_root/checkout" --no-start >/dev/null \
    || fail "installing for a permanent checkout without naming a home was refused"
  pinned_home=$(sed -n 's/^FM_HOME="\(.*\)"$/\1/p' "$case_root/config/firstmate/dashboard.env")
  [ "$pinned_home" = "$case_root/checkout" ] \
    || fail "the unit pins its operational home at [$pinned_home] rather than the permanent checkout"

  # An operational home that is itself a linked worktree is refused for the same
  # reason the checkout is, however it came to be named.
  rm -f "$unit"
  set +e
  out=$(env -u FM_DASHBOARD_EVENTS_CONFIG -u FM_DASHBOARD_AUTH_FILE \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_HOME="$case_root/scratch" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" \
    "$case_root/scratch/bin/fm-dashboard-install.sh" \
    --checkout "$case_root/checkout" --no-start 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an operational home inside a linked worktree"
  assert_contains "$out" "operational home" "the refusal did not name which path was disposable"
  [ ! -f "$unit" ] || fail "a unit pinning a disposable operational home was written anyway"

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

# The installer's gate has to be the server's gate. A credentials file that is
# there but that the server would refuse at startup is not credentials: taking
# it as such writes a unit for a service that comes up only to exit, and leaves
# an operator reading an installation report for a dashboard that is dead.
test_exposure_requires_usable_credentials() {
  local case_root out rc auth_file
  case_root="$TMP_ROOT/unusable"
  mkdir -p "$case_root/config" "$case_root/home"
  auth_file="$case_root/dashboard-auth.json"

  write_credentials "$auth_file" captain "$PASSWORD"
  chmod 644 "$auth_file"
  set +e
  out=$(install_into "$case_root" --address 192.0.2.7 --auth-file "$auth_file" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a non-loopback bind with credentials other users can read"
  assert_contains "$out" "readable by other users" "the refusal did not say why the credentials were unusable"
  [ ! -f "$case_root/config/systemd/user/firstmate-dashboard.service" ] \
    || fail "an exposed unit was written over credentials the server will refuse"

  printf '{"schema":"fm-dashboard-auth.v1"' > "$auth_file"
  chmod 600 "$auth_file"
  set +e
  out=$(install_into "$case_root" --address 192.0.2.7 --auth-file "$auth_file" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a non-loopback bind with credentials that will not parse"
  assert_contains "$out" "could not be used" "the refusal did not say why the credentials were unusable"

  # The same file, private and whole, is what opens the bind.
  write_credentials "$auth_file" captain "$PASSWORD"
  install_into "$case_root" --address 192.0.2.7 --auth-file "$auth_file" >/dev/null \
    || fail "usable credentials did not open the exposed bind"
  assert_contains "$(cat "$case_root/config/firstmate/dashboard.env")" 'FM_DASHBOARD_ADDRESS="192.0.2.7"' \
    "the exposed bind was not written into the environment file"
  pass "exposure is gated on credentials the server could serve behind, not on a file being present"
}

# systemctl restart returns for a Type=simple service the moment the process
# forks, and every systemctl show read-back answers out of the unit file whether
# or not that process is alive. An installer that reports success on those alone
# reports success over a crash loop.
test_a_service_that_did_not_stay_up_is_not_reported_as_installed() {
  local case_root out rc
  case_root="$TMP_ROOT/liveness"
  mkdir -p "$case_root/config" "$case_root/home" "$case_root/bin"

  run_install_with_stub() {  # <active-state> <restart-count>
    write_systemctl_stub "$case_root/bin" "$1" "$2"
    env -u FM_DASHBOARD_EVENTS_CONFIG -u FM_DASHBOARD_AUTH_FILE -u FM_HOME \
      PATH="$case_root/bin:$PATH" \
      HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
      FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" \
      "$INSTALLER" --allow-worktree --fm-home "$case_root/fleet" 2>&1
  }

  set +e
  out=$(run_install_with_stub failed 0)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a service that never came up was reported as installed"
  assert_contains "$out" "did not stay up" "the failure did not say the service is not running"
  assert_contains "$out" "journalctl" "the failure did not say where to read why"

  # A service between crashes is waiting to be started again, not running, and a
  # crash loop is mostly made of that state.
  set +e
  out=$(run_install_with_stub activating 1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a service waiting to be restarted was reported as installed"
  assert_contains "$out" "did not stay up" "a restarting service was not reported as such"

  out=$(run_install_with_stub active 0) || fail "a running service was not reported as installed"
  assert_contains "$out" "the service is running" "a healthy install did not report the service as running"
  pass "an install is reported as finished only once the service is still running"
}

test_loopback_stays_the_open_default() {
  local case_root env_file
  case_root="$TMP_ROOT/default"
  install_into "$case_root" >/dev/null || fail "the installer did not complete"
  env_file="$case_root/config/firstmate/dashboard.env"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_ADDRESS="127.0.0.1"' \
    "installing without asking for exposure did not stay on loopback"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_TRUSTED_PROXIES=""' \
    "installing without naming a proxy did not leave the allowlist empty"
  [ ! -f "$case_root/config/firstmate/dashboard-auth.json" ] \
    || fail "installing without --set-password invented credentials"
  pass "an install that did not ask for exposure stays loopback-only"
}

# The allowlist decides who a request is throttled as, so a value that reaches
# the unit has to be one the server would accept, and a name has to be refused
# for the same reason the bind address refuses one.
test_a_trusted_proxy_is_pinned_only_when_the_server_accepts_it() {
  local case_root out rc
  case_root="$TMP_ROOT/trusted-proxy"
  mkdir -p "$case_root/config" "$case_root/home"

  install_into "$case_root" --trusted-proxy 192.0.2.10 --trusted-proxy 198.51.100.0/24 >/dev/null \
    || fail "naming trusted proxies was refused"
  assert_contains "$(cat "$case_root/config/firstmate/dashboard.env")" \
    'FM_DASHBOARD_TRUSTED_PROXIES="192.0.2.10,198.51.100.0/24"' \
    "the named proxies were not pinned into the environment file"

  set +e
  out=$(install_into "$case_root" --trusted-proxy proxy.invalid 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a trusted proxy given as a name"
  assert_contains "$out" "proxy.invalid" "the refusal did not name the unusable entry"

  # Trusting every address there is, is not a narrower allowlist but the absence
  # of one, and it would hand identity to whoever sends the header.
  set +e
  out=$(install_into "$case_root" --trusted-proxy 0.0.0.0/0 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a trusted-proxy range covering every address"

  # What the installer asks the server is captured and then written into the
  # unit's configuration, so anything the probe writes to standard error while
  # still succeeding - an operator's NODE_OPTIONS here, a future deprecation
  # notice in practice - must not become an entry in the allowlist that decides
  # whose forwarded headers are believed.
  local noisy_options='--experimental-loader=data:text/javascript,'
  if [ -z "$(NODE_OPTIONS="$noisy_options" node "$SERVER" --check-trusted-proxies 2>&1 >/dev/null)" ]; then
    echo "skip: this node emits nothing on standard error for the noise probe"
  else
    INSTALLER_NODE_OPTIONS=$noisy_options
    install_into "$case_root" --trusted-proxy 192.0.2.10 >/dev/null \
      || fail "a noisy but successful probe made the installer refuse a usable proxy"
    INSTALLER_NODE_OPTIONS=
    local env_file pinned
    env_file="$case_root/config/firstmate/dashboard.env"
    pinned=$(sed -n 's/^FM_DASHBOARD_TRUSTED_PROXIES="\(.*\)"$/\1/p' "$env_file")
    [ "$pinned" = "192.0.2.10" ] \
      || fail "the pinned allowlist is [$pinned] rather than exactly the named proxy"
    assert_not_contains "$(cat "$env_file")" "Warning" \
      "process noise from the probe reached the environment file"
  fi
  pass "a trusted proxy is validated by the server that will honour it before any unit names it"
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

  start_server_on "$case_root" "$address"

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

# The wildcard binds are the ones that already answer on 127.0.0.1 themselves, so
# a companion loopback listener added for every non-loopback address would be a
# second socket on an address this process is already holding - and the service
# would not start at all on a configuration bin/fm-dashboard-install.sh permits
# with a warning and docs/dashboard-remote-access.md calls supported. Keying this
# on a real interface address would not have caught it.
test_a_wildcard_bind_starts_and_still_answers_on_loopback() {
  local case_root code
  case_root="$TMP_ROOT/wildcard"
  mkdir -p "$case_root"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"

  start_server_on "$case_root" 0.0.0.0
  code=$(status_for /api/snapshot -u "captain:$PASSWORD")
  expect_code 200 "$code" "an authenticated request over loopback under a wildcard bind"
  code=$(status_for /api/snapshot)
  expect_code 401 "$code" "an unauthenticated request over loopback under a wildcard bind"
  assert_not_contains "$(cat "$case_root/server.log")" "EADDRINUSE" \
    "the wildcard bind collided with a listener of its own"
  kill -0 "$SERVER_PID" 2>/dev/null || fail "the wildcard-bound dashboard did not stay up"
  stop_server

  # The same, spelled as the IPv6 wildcard, which covers loopback on a
  # dual-stack host the same way.
  if node -e 'const s=require("net").createServer();s.once("error",()=>process.exit(1));s.listen(0,"::",()=>{s.close();process.exit(0)})' 2>/dev/null; then
    start_server_on "$case_root" ::
    code=$(status_for /api/snapshot -u "captain:$PASSWORD")
    expect_code 200 "$code" "an authenticated request over loopback under an IPv6 wildcard bind"
    kill -0 "$SERVER_PID" 2>/dev/null || fail "the ::-bound dashboard did not stay up"
    stop_server
  fi
  pass "a wildcard bind starts and keeps answering on loopback under the same authentication"
}

# The startup path of the same rule test_credentials_losing_their_private_mode_
# close_the_dashboard covers for a file that breaks later. Identical on-disk
# state must get the identical answer whichever side of process start it broke
# on: a credential this server cannot use closes the dashboard, because "I could
# not read the credentials" is not "there are no credentials".
test_credentials_already_unusable_at_startup_close_the_dashboard() {
  local case_root code body
  case_root="$TMP_ROOT/startup-credentials"
  mkdir -p "$case_root"

  # Present, but readable by other users - a file restored or copied under a
  # default umask, which is how this state is reached in practice.
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"
  chmod 644 "$case_root/dashboard-auth.json"
  start_authenticated_server "$case_root"
  code=$(status_for /api/snapshot)
  expect_code 503 "$code" "an unauthenticated request against credentials exposed before startup"
  code=$(status_for /api/snapshot -u "captain:$PASSWORD")
  expect_code 503 "$code" "an authenticated request against credentials exposed before startup"

  # A refusal an operator cannot act on is its own defect, so it names the file,
  # what was wrong with it, and the command that puts a usable one back.
  body=$(curl -s "http://127.0.0.1:$TEST_PORT/api/snapshot")
  assert_contains "$body" "$case_root/dashboard-auth.json" "the refusal did not name the credentials file"
  assert_contains "$body" "readable by other users" "the refusal did not say what was wrong with it"
  assert_contains "$body" "--set-password" "the refusal did not say how to recover"
  stop_server

  # Present, private, and not a credentials document at all.
  printf '{"schema":"fm-dashboard-auth.v1"' > "$case_root/dashboard-auth.json"
  chmod 600 "$case_root/dashboard-auth.json"
  start_authenticated_server "$case_root"
  code=$(status_for /api/snapshot)
  expect_code 503 "$code" "an unauthenticated request against credentials that will not parse"
  body=$(curl -s "http://127.0.0.1:$TEST_PORT/api/snapshot")
  assert_contains "$body" "$case_root/dashboard-auth.json" "the parse refusal did not name the credentials file"
  assert_contains "$body" "--set-password" "the parse refusal did not say how to recover"
  stop_server
  pass "credentials that were already unusable at startup close the dashboard instead of opening it"
}

# The throttle protects the key derivation a guess would cost, so it is charged
# before the derivation. What it must not do is charge the people it exists to
# keep serving: the shared budget refills at one token a second, so a client
# spending it on correct passwords - or an attacker spending it on wrong ones -
# would otherwise hold every legitimate first login at 429.
test_correct_credentials_do_not_spend_the_failure_budget() {
  local case_root code attempt encoded spacing
  case_root="$TMP_ROOT/refund"
  mkdir -p "$case_root"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"
  start_authenticated_server "$case_root"
  encoded=$(printf '%s' "captain:$PASSWORD" | base64 | tr -d '\n')

  # Each request carries the same credential under a header this server has not
  # seen before, so every one of them is a real verification rather than a
  # remembered session, and each spends a token unless a success gives it back.
  # The per-client budget is smaller than this many attempts.
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    spacing=$(printf "%${attempt}s" '')
    code=$(status_for /api/snapshot -H "Authorization: Basic${spacing}${encoded}")
    expect_code 200 "$code" "correct credentials on attempt $attempt"
  done

  # The budget still exists: a wrong password is still refused, not admitted.
  code=$(status_for /api/snapshot -u "captain:$PASSWORD-wrong")
  [ "$code" = "401" ] || [ "$code" = "429" ] || fail "a wrong password answered $code"
  stop_server
  pass "correct credentials are not charged the budget that throttles wrong ones"
}

# How many wrong passwords in a row it takes before this client is throttled,
# or "never" when the whole run stayed refused-but-not-throttled. One number
# says whether two requests shared a bucket, which is the entire question every
# client-identity case below asks.
guesses_until_throttled() {  # [curl args...]
  local attempt code
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    code=$(status_for /api/snapshot -u "captain:wrong-$attempt-password" "$@")
    if [ "$code" = "429" ]; then printf '%s\n' "$attempt"; return 0; fi
    [ "$code" = "401" ] || { printf 'unexpected-%s\n' "$code"; return 0; }
  done
  printf 'never\n'
}

# Who a request is throttled as, which behind a reverse proxy is the difference
# between per-client throttling and none.
#
# Every case here is a bucket-sharing question, and the answer is read off
# whether a run of wrong passwords from nominally different clients exhausts one
# budget. Both directions are pinned deliberately: an implementation that
# believed every X-Forwarded-For would pass the honoured case and fail the two
# ignored ones, and an implementation that read the leftmost entry would pass
# both of those and fail the forging case.
test_forwarded_client_identity_is_only_read_from_a_trusted_proxy() {
  local case_root code before after
  case_root="$TMP_ROOT/forwarded"
  mkdir -p "$case_root"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"

  # Nothing configured: the shipped default reads no forwarded header at all, so
  # a client that sends a different one every time is still one client.
  TRUSTED_PROXIES=
  start_authenticated_server "$case_root"
  before=$(guesses_until_throttled -H 'X-Forwarded-For: 203.0.113.1')
  [ "$before" != "never" ] \
    || fail "with no trusted proxy configured, forwarded headers minted identities"
  case $before in unexpected-*) fail "guessing answered $before with no trusted proxy configured" ;; esac
  stop_server

  # A trusted proxy that is not the peer this request came from changes nothing:
  # a header from an untrusted peer is a claim the client made about itself.
  TRUSTED_PROXIES=192.0.2.10
  start_authenticated_server "$case_root"
  after=$(guesses_until_throttled -H 'X-Forwarded-For: 198.51.100.7')
  [ "$after" != "never" ] || fail "a forwarded header from an untrusted peer was believed"
  case $after in unexpected-*) fail "guessing answered $after behind an untrusted peer" ;; esac
  stop_server

  # The peer itself named as a proxy: now the forwarded client is the client.
  TRUSTED_PROXIES=127.0.0.1
  start_authenticated_server "$case_root"

  # An absent header is not a refusal - the proxy itself may be the client.
  code=$(status_for /api/snapshot -u "captain:$PASSWORD-wrong")
  expect_code 401 "$code" "a request from the trusted proxy with no forwarded header"

  # One guesser must not spend anybody else's budget.
  after=$(guesses_until_throttled -H 'X-Forwarded-For: 203.0.113.21')
  [ "$after" != "never" ] || fail "a forwarded client was never throttled at all"
  case $after in unexpected-*) fail "guessing answered $after through the trusted proxy" ;; esac
  code=$(status_for /api/snapshot -u "captain:wrong-again-password" -H 'X-Forwarded-For: 203.0.113.22')
  expect_code 401 "$code" "a second forwarded client while the first is throttled"
  code=$(status_for /api/snapshot -u "captain:$PASSWORD" -H 'X-Forwarded-For: 203.0.113.23')
  expect_code 200 "$code" "the right password from a client that was not the one guessing"

  # Everything left of the entry the trusted proxy appended is whatever the
  # client chose to claim, so forging a fresh one per request must not buy a
  # fresh budget per request.
  after=$(guesses_until_throttled -H 'X-Forwarded-For: 198.51.100.1, 203.0.113.30')
  [ "$after" != "never" ] || fail "forged leftmost entries minted one identity per request"
  code=$(status_for /api/snapshot -u "captain:wrong-forged-password" -H 'X-Forwarded-For: 198.51.100.2, 203.0.113.30')
  expect_code 429 "$code" "a forged leftmost entry against an already-throttled client"

  # More than one proxy in front is walked past, not just the last hop, so the
  # same client is the same client however many trusted hops it came through.
  after=$(guesses_until_throttled -H 'X-Forwarded-For: 203.0.113.40, 127.0.0.1')
  [ "$after" != "never" ] || fail "a client behind two trusted hops was never throttled"
  case $after in unexpected-*) fail "guessing answered $after behind two trusted hops" ;; esac
  code=$(status_for /api/snapshot -u "captain:wrong-hop-password" -H 'X-Forwarded-For: 203.0.113.40')
  expect_code 429 "$code" "the same client reached through one trusted hop fewer"

  # A chain the server cannot read is refused rather than counted as some
  # shared client that anyone could then hold empty. The credential is one this
  # server has not seen, so the answer comes from the identity rule rather than
  # from a remembered session.
  code=$(status_for /api/snapshot -u "captain:wrong-malformed-password" -H 'X-Forwarded-For: 203.0.113.5, not-an-address')
  expect_code 403 "$code" "a malformed forwarded chain from the trusted proxy"
  stop_server
  TRUSTED_PROXIES=
  pass "a forwarded client address is read only from a trusted proxy, from the proxy end, or not at all"
}

# A probe is a question, and a server that does not know the question must say
# so. Answering by serving leaves the caller waiting on output that never comes,
# which is how an installer probing an older checkout hangs with a stray
# dashboard listening behind it.
test_an_unrecognised_argument_is_refused_instead_of_served() {
  local case_root out rc port
  case_root="$TMP_ROOT/argv"
  mkdir -p "$case_root/home/data" "$case_root/home/state"
  port=$(free_port)

  set +e
  out=$(fm_run_timed 10 env FM_HOME="$case_root/home" FM_DASHBOARD_PORT="$port" \
    node "$SERVER" --a-mode-this-version-does-not-have 2>&1)
  rc=$?
  set -e
  # 125 is the timeout library's "nothing was executed", which says nothing
  # about the server under test; 124 and 137 are the bound elapsing, which for a
  # probe means it started serving instead of answering.
  [ "$rc" -ne 125 ] || { echo "skip: no bounded runner available for a probe"; return 0; }
  [ "$rc" -ne 0 ] || fail "an unrecognised argument was accepted"
  [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] \
    || fail "an unrecognised argument started a listener instead of refusing"
  assert_contains "$out" "--a-mode-this-version-does-not-have" "the refusal did not name the argument"
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/snapshot")" = "000" ] \
    || fail "a refused probe left something listening on its port"

  # The recognised probes still answer, and still answer promptly.
  out=$(fm_run_timed 10 env FM_HOME="$case_root/home" node "$SERVER" --event-store-path) \
    || fail "the agent-event store probe stopped working"
  case "$out" in /*) ;; *) fail "the agent-event store probe printed [$out]" ;; esac
  set +e
  out=$(fm_run_timed 10 env FM_DASHBOARD_TRUSTED_PROXIES="192.0.2.10,not-an-address" \
    node "$SERVER" --check-trusted-proxies 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unusable trusted-proxy allowlist was accepted"
  [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] \
    || fail "an unusable trusted-proxy allowlist started a listener instead of refusing"
  assert_contains "$out" "not-an-address" "the refusal did not name the unusable entry"
  out=$(fm_run_timed 10 env FM_DASHBOARD_TRUSTED_PROXIES="192.0.2.10, 198.51.100.0/24" \
    node "$SERVER" --check-trusted-proxies) || fail "a usable trusted-proxy allowlist was refused"
  [ "$out" = "192.0.2.10,198.51.100.0/24" ] || fail "the allowlist read back as [$out]"
  pass "an unrecognised argument is refused promptly and never becomes a listener"
}

test_generated_unit_carries_literal_paths
test_a_path_the_unit_cannot_carry_is_refused
test_an_exposed_bind_keeps_loopback
test_a_wildcard_bind_starts_and_still_answers_on_loopback
test_installing_from_a_worktree_is_refused
test_exposure_requires_credentials
test_exposure_requires_usable_credentials
test_a_service_that_did_not_stay_up_is_not_reported_as_installed
test_an_unrecognised_argument_is_refused_instead_of_served
test_loopback_stays_the_open_default
test_a_trusted_proxy_is_pinned_only_when_the_server_accepts_it
test_set_password_stores_only_a_digest
test_a_short_password_is_refused
test_authentication_accepts_and_rejects
test_repeated_wrong_passwords_are_rate_limited
test_correct_credentials_do_not_spend_the_failure_budget
test_forwarded_client_identity_is_only_read_from_a_trusted_proxy
test_credentials_losing_their_private_mode_close_the_dashboard
test_credentials_already_unusable_at_startup_close_the_dashboard
test_ingest_keeps_its_own_boundary
fm_assert_no_user_event_store_leak "$USER_EVENT_STORE_BEFORE"
pass "no agent-event store was created outside this suite's own temp space"
