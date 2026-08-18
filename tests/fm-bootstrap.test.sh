#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh reporting and session-start clone refresh bounds.
#
# Bootstrap prints one block or line per actionable problem, optional verbose
# BOOTSTRAP_INFO fact, or completed bootstrap no-action fact and is silent when
# all is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)',
# 'MISSING: tasks-axi (install: ...)', 'MISSING: quota-axi (install: ...)',
# 'MISSING: gh-axi (install: ...)', 'MISSING: lavish-axi (install: ...)', and
# 'BOOTSTRAP_INFO: ...' lines, so those contracts are pinned verbatim. The cases
# are table-driven over the inputs that vary: whether `treehouse get --help`
# advertises --lease, which (if any) tasks-axi version is on PATH, whether
# tasks-axi update advertises --archive-body, whether its mv help advertises
# multi-ID moves, whether quota-axi is on PATH,
# whether the local backend config opts out of tasks-axi backlog mutations,
# which no-mistakes version is on PATH, which gh-axi version is on PATH, and
# which lavish-axi version is on PATH.
# Dedicated fleet-sync cases pin the computed bootstrap timeout, explicit
# override, blank-env defaulting, partial-output relay, and pre-launch timeout
# scan. The token-usage sweep's cases pin its gates and report lines, while dedicated network-phase cases pin FM_BOOTSTRAP_NETWORK as a true partition and the one-hop tasks-axi compatibility handoff.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
# Keep bootstrap cases independent of the operator's real runtime credential
# store. Individual serving-credential cases can override this fixture path.
export FM_TEST_PI_AUTH_FILE="$TMP_ROOT/absent-auth.json"

# Hermetic runtime-backend detection. These cases pin the backend per-home via
# config/backend; the dev shell's ambient runtime markers ($TMUX inside tmux,
# HERDR_ENV inside herdr, CMUX_* inside a cmux terminal) must not leak into
# fm_backend_name and flip a default-backend case onto a non-tmux backend. Unset
# them once so the suite resolves the tmux reference backend unless a case says
# otherwise - the same hermeticity discipline as pinning PATH via BASE_PATH.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_GH_AXI_VERSION:-0.1.29}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/gbrain" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = config ] && [ "${2:-}" = get ]; then
  home_dir="${GBRAIN_HOME:-}"
  key="${3:-}"
  if [ -f "$home_dir/mock_think_model" ] && [ "$key" = "models.think" ]; then
    cat "$home_dir/mock_think_model"
    exit 0
  elif [ -f "$home_dir/mock_initialized" ]; then
    echo "Config key not found: $key"
    exit 1
  else
    echo "No brain configured. Run: gbrain init"
    exit 1
  fi
fi
exit 0
SH
  chmod +x "$fakebin/gbrain"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  add_tasks_axi "$fakebin" "0.2.4"
  add_quota_axi "$fakebin"
  printf '%s\n' "$fakebin"
}

add_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_QUOTA_AXI_VERSION:-0.1.17}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

add_tasks_axi() {
  local fakebin=$1 version=$2 archive_body=${3:-yes} multi_id=${4:-yes} archive_line mv_usage
  archive_line=""
  [ "$archive_body" = yes ] && archive_line='  --archive-body'
  mv_usage='usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  [ "$multi_id" = yes ] || mv_usage='usage: tasks-axi mv <id> --to <path-or-dir>'
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  [ -z '$archive_line' ] || printf '%s\n' '$archive_line'
  exit 0
fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '$mv_usage'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

add_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for dispatch profile validation tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

make_fake_fleet_sync_root() {
  local dir=$1 fake_root
  fake_root="$dir/fake-root"
  mkdir -p "$fake_root/bin"
cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ] || : > "$FM_FAKE_FLEET_SYNC_STARTED_MARKER"
[ -z "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ] \
  || trap ': > "${FM_FAKE_FLEET_SYNC_STARTED_MARKER}.finished"' EXIT
printf '%s\n' 'alpha: synced'
printf '%s\n' 'beta: skipped: no origin remote'
perl -e 'sleep 300'
SH
  chmod +x "$fake_root/bin/fm-fleet-sync.sh"
  printf '%s\n' "$fake_root"
}

add_origin_backed_projects() {
  local home=$1 count=$2 i repo
  mkdir -p "$home/projects"
  i=1
  while [ "$i" -le "$count" ]; do
    repo=$(printf '%s/projects/repo-%02d' "$home" "$i")
    git init -q "$repo"
    git -C "$repo" remote add origin "file://$home/remotes/repo-$i.git"
    i=$((i + 1))
  done
}

add_no_origin_projects() {
  local home=$1 count=$2 i repo
  mkdir -p "$home/projects"
  i=1
  while [ "$i" -le "$count" ]; do
    repo=$(printf '%s/projects/local-%02d' "$home" "$i")
    git init -q "$repo"
    i=$((i + 1))
  done
}

run_bootstrap_timeout_case() {
  local home=$1 fake_root=$2 fakebin=$3 override started_marker git_record wait_for_marker
  override=__unset__
  started_marker=${5:-}
  git_record=${6:-}
  wait_for_marker=${7:-0}
  [ "$#" -lt 4 ] || override=$4
  (
    # shellcheck disable=SC2317,SC2329 # Exported and invoked by the bootstrap subprocess.
    sleep() {
      local inc=${1:-1}
      SECONDS=$((SECONDS + inc))
      # Advance fake time quickly, but yield on every tick so the background
      # fleet-sync process can deterministically write its partial output before
      # the simulated timeout kills it, even on a busy full-suite runner.
      command sleep 0.01
    }
    # shellcheck disable=SC2317,SC2329 # Exported and invoked by the bootstrap subprocess.
    git() {
      local tries
      if [ "${FM_FAKE_GIT_WAIT_FOR_FLEET_START:-}" = 1 ] && [ -n "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ]; then
        tries=0
        while [ "$tries" -lt 5 ] && [ ! -e "$FM_FAKE_FLEET_SYNC_STARTED_MARKER" ]; do
          command sleep 0.01
          tries=$((tries + 1))
        done
      fi
      if [ -n "${FM_FAKE_GIT_SYNC_STARTED_RECORD:-}" ] \
        && [ -n "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ] \
        && [ -e "$FM_FAKE_FLEET_SYNC_STARTED_MARKER" ] \
        && [ ! -e "${FM_FAKE_FLEET_SYNC_STARTED_MARKER}.finished" ]; then
        printf '%s\n' "$*" >> "$FM_FAKE_GIT_SYNC_STARTED_RECORD"
      fi
      command git "$@"
    }
    export -f sleep
    export -f git
    if [ "$override" = __unset__ ]; then
      PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
        FM_FAKE_FLEET_SYNC_STARTED_MARKER="$started_marker" \
        FM_FAKE_GIT_SYNC_STARTED_RECORD="$git_record" \
        FM_FAKE_GIT_WAIT_FOR_FLEET_START="$wait_for_marker" \
        FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
    else
      PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
        FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT="$override" \
        FM_FAKE_FLEET_SYNC_STARTED_MARKER="$started_marker" \
        FM_FAKE_GIT_SYNC_STARTED_RECORD="$git_record" \
        FM_FAKE_GIT_WAIT_FOR_FLEET_START="$wait_for_marker" \
        FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
    fi
  )
}

assert_timeout_report() {
  local out=$1 expected_timeout=$2 timing timeout elapsed
  timing=$(printf '%s\n' "$out" | sed -n 's/^FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=\([0-9][0-9]*\)s elapsed=\([0-9][0-9]*\)s)$/\1 \2/p')
  [ -n "$timing" ] || fail "missing fleet-sync timeout report"
  timeout=${timing%% *}
  elapsed=${timing#* }
  [ "$timeout" -eq "$expected_timeout" ] || fail "expected timeout=${expected_timeout}s, got timeout=${timeout}s"
  [ "$elapsed" -ge "$timeout" ] || fail "expected elapsed >= timeout, got elapsed=${elapsed}s timeout=${timeout}s"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<quota 1/0>^<backend or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks quota backend mode expect notcontains case_dir fakebin out n archive_body multi_id
  n=0
  while IFS='^' read -r label lease tasks quota backend mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    if [ "$backend" != "-" ]; then
      mkdir -p "$case_dir/home/config"
      printf '%s\n' "$backend" > "$case_dir/home/config/backlog-backend"
    fi
    fakebin=$(make_fake_toolchain "$case_dir")
    if [ "$tasks" = "-" ]; then
      rm -f "$fakebin/tasks-axi"
    else
      archive_body=yes
      multi_id=yes
      case "$tasks" in
        *:noarchive)
          archive_body=no
          tasks=${tasks%:noarchive}
          ;;
      esac
      case "$tasks" in
        *:nomulti)
          multi_id=no
          tasks=${tasks%:nomulti}
          ;;
      esac
      add_tasks_axi "$fakebin" "$tasks" "$archive_body" "$multi_id"
    fi
    if [ "$quota" = "0" ]; then
      rm -f "$fakebin/quota-axi"
    fi
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
treehouse --lease support is accepted silently^1^0.2.4^1^manual^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.2.4^1^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is silent by default^1^0.2.4^1^-^empty^^
missing tasks-axi is required by default^1^-^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi is required by default^1^0.1.0^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without archive-body is required by default^1^0.2.4:noarchive^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without multi-id mv is required by default^1^0.2.4:nomulti^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
missing quota-axi is required by default^1^0.2.4^0^manual^exact^MISSING: quota-axi (install: npm install -g quota-axi)^
manual backlog backend still requires missing tasks-axi^1^-^1^manual^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend suppresses tasks-axi availability^1^0.2.4^1^manual^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi/quota-axi bootstrap contracts"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

test_gh_axi_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/gh-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_GH_AXI_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum gh-axi version is accepted^0.1.29^empty
newer gh-axi patch is accepted^0.1.30^empty
newer gh-axi minor is accepted^0.2.0^empty
newer gh-axi major is accepted^1.0.0^empty
older gh-axi patch reports an upgrade^0.1.19^missing
much older gh-axi minor reports an upgrade^0.0.9^missing
unparseable gh-axi version reports an upgrade^gh-axi development build^missing
ROWS
  pass "bootstrap enforces gh-axi minimum version"
}

test_lavish_axi_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: lavish-axi (install: npm install -g lavish-axi && lavish-axi setup hooks)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/lavish-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_LAVISH_AXI_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum lavish-axi version is accepted^0.1.46^empty
newer lavish-axi patch is accepted^0.1.47^empty
newer lavish-axi minor is accepted^0.2.0^empty
newer lavish-axi major is accepted^1.0.0^empty
the patch just below the floor reports an upgrade^0.1.45^missing
much older lavish-axi minor reports an upgrade^0.0.9^missing
unparseable lavish-axi version reports an upgrade^lavish-axi development build^missing
ROWS
  pass "bootstrap enforces lavish-axi minimum version"
}

test_tasks_axi_min_version() {
  local label version mode case_dir fakebin out missing n archive_body multi_id
  missing='MISSING: tasks-axi (install: npm install -g tasks-axi)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/tasks-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    archive_body=yes
    multi_id=yes
    case "$version" in
      *:noarchive)
        archive_body=no
        version=${version%:noarchive}
        ;;
    esac
    case "$version" in
      *:nomulti)
        multi_id=no
        version=${version%:nomulti}
        ;;
    esac
    add_tasks_axi "$fakebin" "$version" "$archive_body" "$multi_id"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum tasks-axi version is accepted^0.2.4^empty
newer tasks-axi patch is accepted^0.2.5^empty
newer tasks-axi minor is accepted^0.3.0^empty
newer tasks-axi major is accepted^1.0.0^empty
older tasks-axi with features reports an upgrade^0.1.1^missing
the patch just below the floor reports an upgrade^0.2.3^missing
unparseable tasks-axi version reports an upgrade^tasks-axi development build^missing
tasks-axi at floor without archive-body reports an upgrade^0.2.4:noarchive^missing
tasks-axi at floor without multi-id reports an upgrade^0.2.4:nomulti^missing
ROWS
  pass "bootstrap enforces tasks-axi minimum version"
}

# These rows exercise the real bootstrap check with a fake quota-axi answering
# --version: below the floor produces MISSING, while at or above is silent.
test_quota_axi_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: quota-axi (install: npm install -g quota-axi)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/quota-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_QUOTA_AXI_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum quota-axi version is accepted^0.1.17^empty
newer quota-axi patch is accepted^0.1.18^empty
newer quota-axi minor is accepted^0.2.0^empty
newer quota-axi major is accepted^1.0.0^empty
the patch just below the floor reports an upgrade^0.1.16^missing
much older quota-axi minor reports an upgrade^0.0.9^missing
unparseable quota-axi version reports an upgrade^quota-axi development build^missing
ROWS
  pass "bootstrap enforces quota-axi minimum version"
}

test_git_is_required_with_supported_install_instruction() {
  local case_dir fakebin bash_env out expected
  case_dir="$TMP_ROOT/git-required"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  bash_env="$case_dir/no-git.bash"
  cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = git ]; then
    return 1
  fi
  builtin command "$@"
}
git() {
  return 127
}
SH

  out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  expected="MISSING: git (install: brew install git  # or the platform's package manager)"
  [ "$out" = "$expected" ] || fail "missing git should report the supported install instruction, got: $out"
  pass "bootstrap requires git with an install instruction"
}

test_orca_backend_gates_orca_tool_only_when_selected() {
  local case_dir fakebin out missing_orca
  missing_orca="MISSING: orca (install: brew install orca  # or the platform's package manager)"

  case_dir="$TMP_ROOT/orca-backend-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_orca" ] || fail "backend=orca should require only the Orca-specific missing tool, got: $out"

  case_dir="$TMP_ROOT/orca-backend-not-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: orca" "bootstrap should not require orca unless backend=orca is selected"
  pass "bootstrap: backend=orca gates the Orca CLI without requiring it on the default backend"
}

# Build a fake toolchain with tmux REMOVED and the named backend session CLI(s)
# plus jq added, so a backend that must NOT require tmux can be proven silent
# with tmux absent. Echoes the fakebin dir. The removed tmux is what makes these
# cases catch the old "everything but orca demands tmux" bug: with the buggy
# TOOLS list a herdr/zellij/cmux home would report MISSING: tmux here.
make_fake_toolchain_no_tmux() {  # <case-dir> <extra-cli...>
  local dir=$1 fakebin
  shift
  fakebin=$(make_fake_toolchain "$dir")
  rm -f "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" jq "$@"
  printf '%s\n' "$fakebin"
}

test_session_provider_backends_do_not_require_tmux() {
  local backend cli case_dir fakebin out
  # herdr/zellij/cmux are session providers only: they require their own CLI, jq,
  # and treehouse, never tmux. With all genuine deps present and tmux absent,
  # bootstrap must be silent.
  while IFS='^' read -r backend cli; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-no-tmux"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    fakebin=$(make_fake_toolchain_no_tmux "$case_dir" "$cli")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    [ -z "$out" ] || fail "backend=$backend with tmux absent but its own deps present should be silent, got: $out"
  done <<'ROWS'
herdr^herdr
zellij^zellij
cmux^cmux
ROWS
  pass "bootstrap: session-provider backends require their own CLI + jq + treehouse, never tmux"
}

test_session_provider_backends_gate_own_cli_not_tmux() {
  local backend cli case_dir fakebin out missing
  # With the backend's OWN session CLI absent (and tmux also absent), bootstrap
  # must fail closed on the genuine dep and never substitute a false tmux demand.
  while IFS='^' read -r backend cli; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-missing-cli"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    # Toolchain has jq + treehouse but NOT the session CLI and NOT tmux.
    fakebin=$(make_fake_toolchain_no_tmux "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    if [ "$backend" = herdr ]; then
      missing="MISSING_MANUAL: herdr (instructions: https://herdr.dev)"
    else
      missing="MISSING: $cli"
    fi
    assert_contains "$out" "$missing" "backend=$backend must fail closed on its own missing session CLI"
    if [ "$backend" = herdr ]; then
      assert_not_contains "$out" "MISSING: herdr (install:" \
        "backend=herdr must not advertise manual guidance as an executable install command"
    fi
    assert_not_contains "$out" "MISSING: tmux" "backend=$backend must not demand tmux when its own CLI is missing"
  done <<'ROWS'
herdr^herdr
zellij^zellij
cmux^cmux
ROWS
  pass "bootstrap: a session-provider backend gates its own CLI, never a false tmux requirement"
}

test_herdr_install_requires_manual_action() {
  local out status
  out=$("$ROOT/bin/fm-bootstrap.sh" install herdr 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "install herdr should fail instead of evaluating its manual-install hint"
  [ "$out" = "error: herdr requires manual installation (instructions: https://herdr.dev)" ] \
    || fail "install herdr should return actionable manual-install guidance, got: $out"
  pass "bootstrap: Herdr manual-install guidance is never executed as a shell command"
}

test_cmux_bundled_cli_satisfies_dependency() {
  local case_dir fakebin bundle out
  case_dir="$TMP_ROOT/cmux-bundled-cli"
  mkdir -p "$case_dir/home/config" "$case_dir/bundle"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' cmux > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain_no_tmux "$case_dir")
  fm_fake_exit0 "$case_dir/bundle" cmux
  bundle="$case_dir/bundle/cmux"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BACKEND_CMUX_BUNDLE_BIN="$bundle" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "a usable bundled cmux CLI should satisfy bootstrap without a PATH shim, got: $out"
  pass "bootstrap: the bundled cmux CLI satisfies the active backend dependency"
}

test_unknown_backend_reports_invalid_configuration() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/unknown-backend"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' bogus > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "BACKEND_INVALID: bogus (known: tmux herdr zellij orca cmux)" \
    "bootstrap should report an unknown resolved backend"
  assert_not_contains "$out" "MISSING: tmux" "an unknown backend should not silently fall back to tmux dependencies"
  pass "bootstrap: unknown resolved backends fail closed with an actionable diagnostic"
}

test_json_backends_require_jq_not_tmux() {
  local backend case_dir fakebin bash_env out
  # herdr/zellij/cmux parse their backend's JSON output, so jq is a genuine dep.
  # jq lives in a system BASE_PATH dir on many hosts, so force it missing with a
  # command()/jq() override (the same technique the git-required case uses) to keep
  # the assertion host-independent.
  while IFS='^' read -r backend; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-missing-jq"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    # Session CLI present, tmux absent, jq deliberately NOT stubbed and masked below.
    fakebin=$(make_fake_toolchain "$case_dir")
    rm -f "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" "$backend"
    bash_env="$case_dir/no-jq.bash"
    cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  return 127
}
SH
    out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    assert_contains "$out" "MISSING: jq" "backend=$backend must fail closed on missing jq"
    assert_not_contains "$out" "MISSING: tmux" "backend=$backend must not demand tmux when jq is missing"
  done <<'ROWS'
herdr
zellij
cmux
ROWS
  pass "bootstrap: JSON-emitting backends require jq (their genuine dep), never tmux"
}

test_treehouse_lease_check_follows_resolved_backend() {
  local case_dir fakebin out
  # A treehouse that lacks durable --lease support is only a problem for a backend
  # that actually uses treehouse. Orca owns its own worktrees, so an old treehouse
  # must NOT trip MISSING: treehouse under backend=orca...
  case_dir="$TMP_ROOT/orca-old-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  rm -f "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" orca
  # FM_FAKE_TREEHOUSE_LEASE_HELP unset: the fake treehouse advertises NO --lease.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "backend=orca must not require treehouse (even lease-less) or tmux, got: $out"

  # ...but the same lease-less treehouse IS a problem for a session-provider
  # backend that relies on treehouse for worktrees.
  case_dir="$TMP_ROOT/herdr-old-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' herdr > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain_no_tmux "$case_dir" herdr)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: treehouse" "backend=herdr must still require treehouse with durable lease support"
  assert_not_contains "$out" "MISSING: tmux" "backend=herdr must not demand tmux even when treehouse is too old"
  pass "bootstrap: the treehouse lease check follows the resolved backend's worktree provider"
}

test_fleet_sync_timeout_scales_with_origin_backed_project_count() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-scaled"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  add_no_origin_projects "$home" 3
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin")

  assert_contains "$out" $'FLEET_SYNC: alpha: synced\nFLEET_SYNC: beta: skipped: no origin remote' "bootstrap timeout should relay partial fleet-sync output first"
  assert_timeout_report "$out" 59
  pass "bootstrap computes a fleet-size-aware default timeout and preserves partial fleet-sync output"
}

test_fleet_sync_timeout_floor_preserves_small_fleets() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-small"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 2
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin")

  assert_timeout_report "$out" 20
  pass "bootstrap keeps the quick 20s default for small fleets"
}

test_fleet_sync_timeout_explicit_override_wins() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-override"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" 7)

  assert_timeout_report "$out" 7
  assert_not_contains "$out" "timeout=59s" "explicit override should not be replaced by the computed timeout"
  pass "bootstrap preserves FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT as an explicit override"
}

test_fleet_sync_timeout_empty_override_uses_default() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-empty-override"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" "")

  assert_timeout_report "$out" 59
  assert_not_contains "$out" "timeout=20s" "blank timeout env should not force the legacy floor on a large fleet"
  pass "bootstrap treats a blank timeout override as unset"
}

test_fleet_sync_timeout_is_computed_before_launch() {
  local case_dir home fakebin fake_root out started_marker git_record
  case_dir="$TMP_ROOT/fleet-timeout-launch-order"
  home="$case_dir/home"
  started_marker="$case_dir/fleet-started"
  git_record="$case_dir/git-after-start"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 3
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" __unset__ "$started_marker" "$git_record" 1)

  [ ! -s "$git_record" ] || fail "fleet sync launched before timeout scan finished: $(tr '\n' ';' < "$git_record")"
  assert_contains "$out" $'FLEET_SYNC: alpha: synced\nFLEET_SYNC: beta: skipped: no origin remote' "launch-order case should relay partial fleet-sync output before reporting its timeout"
  assert_timeout_report "$out" 20
  pass "bootstrap computes the timeout before launching fleet sync"
}

# --- the bounded token-usage store refresh -----------------------------------
#
# The usage sweep publishes two gates and three lines that a session start is
# read for, so each one is pinned here the way the fleet-sync timeout report
# above is. The sweep runs `node <bin>/fm-usage.mjs ingest` under a bound, so a
# fake node is what makes every outcome reachable without a real collection over
# this machine's transcripts: it records the arguments it was handed, then
# behaves the way the case needs.

make_usage_refresh_case() {  # <case-dir> <node body> -> <home>|<fakebin>|<ran record>
  local case_dir=$1 node_body=$2 home fakebin ran
  home="$case_dir/home"
  ran="$case_dir/usage-ran"
  mkdir -p "$home/config" "$home/data"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
[ -z "\${FM_FAKE_USAGE_RAN:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_USAGE_RAN"
$node_body
SH
  chmod +x "$fakebin/node"
  printf '%s|%s|%s\n' "$home" "$fakebin" "$ran"
}

run_usage_refresh_case() {  # <home> <fakebin> <ran record> [name=value...]
  local home=$1 fakebin=$2 ran=$3
  local -a outer=()
  shift 3
  rm -f "$ran"
  # An outer bound of its own, because a collector that ignores SIGTERM is
  # exactly what the sweep's bound has to survive: if that bound ever stopped
  # escalating to SIGKILL, bootstrap would wait forever and this suite would
  # hang instead of reporting anything. The outer bound turns that into a failed
  # assertion, and escalates the same way for the same reason.
  command -v timeout >/dev/null 2>&1 && outer=(timeout -k 5 60)
  "${outer[@]+"${outer[@]}"}" env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_USAGE_RAN="$ran" "$@" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

assert_usage_collector_ran() {  # <ran record> <home> <message>
  grep -Fq "fm-usage.mjs ingest --home $2" "$1" 2>/dev/null \
    || fail "$3 (recorded: $(cat "$1" 2>/dev/null))"
}

assert_usage_collector_silent() {  # <out> <ran record> <message>
  [ ! -e "$2" ] || fail "$3 (recorded: $(cat "$2"))"
  assert_not_contains "$1" "USAGE_STORE:" "$3"
}

test_usage_store_refresh_is_gated_on_an_existing_store() {
  local case_dir fixture home fakebin ran out
  case_dir="$TMP_ROOT/usage-refresh-gate"
  fixture=$(make_usage_refresh_case "$case_dir" 'exit 0')
  home=${fixture%%|*}
  fixture=${fixture#*|}
  fakebin=${fixture%%|*}
  ran=${fixture#*|}

  out=$(run_usage_refresh_case "$home" "$fakebin" "$ran")
  assert_usage_collector_silent "$out" "$ran" \
    "a home with no data/usage.db must not be opted into the refresh"

  : > "$home/data/usage.db"
  out=$(run_usage_refresh_case "$home" "$fakebin" "$ran")
  assert_usage_collector_ran "$ran" "$home" \
    "an existing store must be refreshed at a locked session boundary"
  assert_not_contains "$out" "USAGE_STORE:" "a completed refresh must stay silent"
  pass "bootstrap refreshes the usage store only where one exists, and says nothing when it works"
}

test_usage_store_refresh_skips_a_detect_only_session() {
  local case_dir fixture home fakebin ran out
  case_dir="$TMP_ROOT/usage-refresh-detect-only"
  fixture=$(make_usage_refresh_case "$case_dir" 'exit 0')
  home=${fixture%%|*}
  fixture=${fixture#*|}
  fakebin=${fixture%%|*}
  ran=${fixture#*|}
  : > "$home/data/usage.db"

  out=$(run_usage_refresh_case "$home" "$fakebin" "$ran" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_usage_collector_silent "$out" "$ran" \
    "a detect-only session must never write the usage store a concurrent session owns"
  pass "bootstrap leaves the usage store alone in a lock-refused detect-only session"
}

# The fake collector ignores SIGTERM on purpose. SIGTERM alone is not a bound -
# a collector that ignores it, or one stuck in uninterruptible IO, would park
# session start past the deadline - so the sweep escalates to SIGKILL, and a
# collector that dies to the polite signal would pin the line while leaving that
# escalation free to be dropped. This one only dies to the kill.
test_usage_store_refresh_reports_its_timeout() {
  local case_dir fixture home fakebin ran out timing timeout elapsed
  case_dir="$TMP_ROOT/usage-refresh-timeout"
  fixture=$(make_usage_refresh_case "$case_dir" $'trap \'\' TERM\nsleep 300')
  home=${fixture%%|*}
  fixture=${fixture#*|}
  fakebin=${fixture%%|*}
  ran=${fixture#*|}
  : > "$home/data/usage.db"

  out=$(run_usage_refresh_case "$home" "$fakebin" "$ran" FM_BOOTSTRAP_USAGE_TIMEOUT=1)

  assert_usage_collector_ran "$ran" "$home" "the timeout case must have started the collector"
  timing=$(printf '%s\n' "$out" | sed -n 's/^USAGE_STORE: skipped: bootstrap refresh timed out (timeout=\([0-9][0-9]*\)s elapsed=\([0-9][0-9]*\)s)$/\1 \2/p')
  [ -n "$timing" ] || fail "missing usage-store timeout report (got: $out)"
  timeout=${timing%% *}
  elapsed=${timing#* }
  [ "$timeout" -eq 1 ] || fail "expected timeout=1s, got timeout=${timeout}s"
  [ "$elapsed" -ge "$timeout" ] || fail "expected elapsed >= timeout, got elapsed=${elapsed}s timeout=${timeout}s"
  pass "bootstrap kills a usage refresh that ignores SIGTERM and reports the bound it spent"
}

# Zero is the input that reads as valid to a digit check and disables the bound
# in every runner underneath it: GNU timeout documents DURATION 0 as "no
# timeout", and the portable arm's `alarm 0` cancels the alarm outright. Either
# would run a scan of every transcript on the machine unbounded at session
# start, which is the one thing this sweep refuses to do, so the fallback is
# pinned on both sides: the collector still runs, and the run still says nothing.
test_usage_store_refresh_falls_back_from_a_zero_bound() {
  local case_dir fixture home fakebin ran out
  case_dir="$TMP_ROOT/usage-refresh-zero"
  fixture=$(make_usage_refresh_case "$case_dir" 'exit 0')
  home=${fixture%%|*}
  fixture=${fixture#*|}
  fakebin=${fixture%%|*}
  ran=${fixture#*|}
  : > "$home/data/usage.db"

  out=$(run_usage_refresh_case "$home" "$fakebin" "$ran" FM_BOOTSTRAP_USAGE_TIMEOUT=0)

  assert_usage_collector_ran "$ran" "$home" "a zero bound must fall back to the default rather than skip the refresh"
  assert_not_contains "$out" "USAGE_STORE:" \
    "a zero bound must fall back to the default, not be handed to a runner that reads it as no bound at all"
  pass "bootstrap treats a zero usage bound as invalid and falls back to the default"
}

test_usage_store_refresh_reports_a_collector_that_failed() {
  local case_dir fixture home fakebin ran out status
  case_dir="$TMP_ROOT/usage-refresh-failed"
  fixture=$(make_usage_refresh_case "$case_dir" 'exit 7')
  home=${fixture%%|*}
  fixture=${fixture#*|}
  fakebin=${fixture%%|*}
  ran=${fixture#*|}
  : > "$home/data/usage.db"

  out=$(run_usage_refresh_case "$home" "$fakebin" "$ran")

  assert_usage_collector_ran "$ran" "$home" "the failure case must have run the collector"
  status=$(printf '%s\n' "$out" | sed -n 's/^USAGE_STORE: failed: bootstrap refresh ran but exited \([0-9][0-9]*\) (elapsed=[0-9][0-9]*s)$/\1/p')
  [ "$status" = 7 ] || fail "expected the collector's own exit status on the failure line (got: $out)"
  assert_not_contains "$out" "USAGE_STORE: skipped" \
    "a refresh that ran and committed part of its work must not be reported as skipped"
  pass "bootstrap reports a usage refresh that ran and failed as failed, not skipped"
}

# BASE_PATH minus every external timeout tool, so the dependency-free bash
# fallback is exercised without pretending the rest of the toolchain is absent.
make_bash_timeout_path() {  # <dir>
  local dir=$1 entry candidate name
  local IFS=:
  mkdir -p "$dir"
  for entry in $BASE_PATH; do
    [ -d "$entry" ] || continue
    for candidate in "$entry"/*; do
      name=${candidate##*/}
      case "$name" in timeout|gtimeout|perl) continue ;; esac
      [ -e "$dir/$name" ] || ln -s "$candidate" "$dir/$name" 2>/dev/null
    done
  done
  printf '%s\n' "$dir"
}

test_usage_store_refresh_uses_bash_fallback() {
  local case_dir fixture home fakebin ran out bash_path
  case_dir="$TMP_ROOT/usage-refresh-bash-timeout"
  fixture=$(make_usage_refresh_case "$case_dir" 'exit 0')
  home=${fixture%%|*}
  fixture=${fixture#*|}
  fakebin=${fixture%%|*}
  ran=${fixture#*|}
  : > "$home/data/usage.db"
  bash_path=$(make_bash_timeout_path "$case_dir/bash-timeout-path")

  rm -f "$ran"
  out=$(PATH="$fakebin:$bash_path" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_USAGE_RAN="$ran" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_usage_collector_ran "$ran" "$home" \
    "the dependency-free bash fallback did not run the bounded usage refresh"
  assert_not_contains "$out" "USAGE_STORE:" \
    "a successful refresh through the bash fallback must remain silent"
  pass "bootstrap bounds the usage refresh with bash when external timeout tools are absent"
}

make_routine_bootstrap_fixture() {
  local case_dir=$1 fakebin root home sm c1
  root="$case_dir/root"
  home="$case_dir/home"
  sm="$case_dir/sm"
  fm_git_identity
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' '{"rules":[{"when":"normal work","use":{"harness":"codex"}}],"default":{"harness":"claude","effort":"low"}}' \
    > "$home/config/crew-dispatch.json"
  git init -q -b main "$root"
  {
    printf '%s\n' '.fm-secondmate-home'
    printf '%s\n' 'config/crew-harness'
    printf '%s\n' 'config/crew-dispatch.json'
    printf '%s\n' 'config/startup-memory-budget'
  } > "$root/.gitignore"
  printf '%s\n' 'instructions' > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' 'echo ok' > "$root/bin/fm-spawn.sh"
  printf '%s\n' 'skill' > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$sm" "$c1"
  printf '%s\n' sm > "$sm/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '%s\n' 0 ;;
      *) printf '%s\n' codex ;;
    esac
    ;;
  capture-pane) printf '❯\n' ;;
  list-windows) printf '%s\n' fm-sm ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

run_routine_bootstrap_fixture() {
  local shell=$1 case_dir=$2 fixture root home fakebin
  fixture=$(make_routine_bootstrap_fixture "$case_dir")
  root=${fixture%%|*}
  fixture=${fixture#*|}
  home=${fixture%%|*}
  fakebin=${fixture#*|}
  PATH="$fakebin:$BASE_PATH" FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$shell" "$ROOT/bin/fm-bootstrap.sh"
}

test_routine_bootstrap_confirmations_are_silent() {
  local out
  out=$(run_routine_bootstrap_fixture bash "$TMP_ROOT/routine-silent")
  [ -z "$out" ] || fail "routine bootstrap confirmations should be silent, got: $out"
  pass "bootstrap keeps routine tasks-axi, harness, dispatch, and already-live liveness confirmations silent"
}

test_routine_bootstrap_contract_runs_under_system_bash() {
  local out
  [ -x /bin/bash ] || { pass "bootstrap routine contract skipped without /bin/bash"; return; }
  out=$(run_routine_bootstrap_fixture /bin/bash "$TMP_ROOT/routine-bash")
  [ -z "$out" ] || fail "routine bootstrap contract should be silent under /bin/bash, got: $out"
  pass "bootstrap routine contract runs under system /bin/bash"
}

# Vault drift is detection only, so bootstrap must surface it in BOTH the normal
# and the detect-only (lock-refused) session, and never rewrite the clone.
# bin/fm-vault-drift.sh's own suite owns the vault shapes and thresholds.
test_bootstrap_relays_vault_drift_in_both_modes() {
  local case_dir fakebin proj out i mode seed
  case_dir="$TMP_ROOT/vault-drift"
  mkdir -p "$case_dir/home/bin" "$case_dir/home/config" "$case_dir/home/projects"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")

  proj="$case_dir/home/projects/hermes"
  mkdir -p "$proj/vault"
  git -C "$proj" init -q
  git -C "$proj" config user.name fmtest
  git -C "$proj" config user.email fmtest@example.invalid
  printf '%s\n' '# Vault home' > "$proj/vault/00-Home.md"
  git -C "$proj" add -A
  GIT_AUTHOR_DATE='@1700000000 +0000' GIT_COMMITTER_DATE='@1700000000 +0000' \
    git -C "$proj" commit -qm 'vault: seed'
  seed=$(git -C "$proj" rev-parse HEAD)
  for ((i = 1; i <= 20; i++)); do
    printf '%s\n' "change $i" > "$proj/file-$i.txt"
    git -C "$proj" add -A
    GIT_AUTHOR_DATE='@1700086400 +0000' GIT_COMMITTER_DATE='@1700086400 +0000' \
      git -C "$proj" commit -qm "work $i"
  done
  git -C "$proj" branch upstream
  git -C "$proj" reset -q --hard "$seed"
  cat > "$case_dir/home/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
git -C "$FM_FAKE_VAULT_PROJECT" merge -q --ff-only upstream
SH
  chmod +x "$case_dir/home/bin/fm-fleet-sync.sh"

  for mode in 0 1; do
    if [ "$mode" -eq 0 ]; then
      git -C "$proj" reset -q --hard "$seed"
    else
      git -C "$proj" reset -q --hard upstream
    fi
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_BOOTSTRAP_DETECT_ONLY="$mode" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
      FM_FAKE_VAULT_PROJECT="$proj" "$ROOT/bin/fm-bootstrap.sh")
    printf '%s\n' "$out" \
      | grep -F 'VAULT_DRIFT: hermes: in-repo vault stale at vault/ - vault last updated 2023-11-14, 20 project commits landed since, drift window 1d' \
        >/dev/null \
      || fail "detect-only=$mode: bootstrap must relay the vault drift line (got: $out)"
  done
  [ -z "$(git -C "$proj" status --porcelain)" ] \
    || fail "bootstrap's vault check must leave the clone untouched"
  pass "bootstrap checks post-sync drift normally and relays it in detect-only sessions"
}

# The serving-credential rule is a startup diagnostic, not an operator-memory
# check: every normal and detect-only session must surface an existing violation.
# Fail by: removing bootstrap's serving-check invocation, weakening it to only
# one session mode, or letting the detector infer any plane as clean.
test_bootstrap_relays_gbrain_serving_credential_in_both_modes() {
  local case_dir home fakebin bash_env out mode expected
  case_dir="$TMP_ROOT/gbrain-serving-credential"
  home="$case_dir/home"
  mkdir -p "$home/config/gbrain-secrets" "$home/data/gbrain/runtime" "$home/data/gbrain/pglite"
  touch "$home/data/gbrain/runtime/mock_initialized"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' \
    '{"version":1,"think":{"base_url":"https://api.example.invalid/v1","model":"minimax:MiniMax-M3","secret":"hosted-synthesis"}}' \
    > "$home/config/gbrain.json"
  printf '%s\n' '{"version":1,"main_brain_owner":true}' > "$home/config/gbrain-local.json"
  printf '%s\n' 'test-only-hosted-key' > "$home/config/gbrain-secrets/hosted-synthesis"
  chmod 600 "$home/config/gbrain-secrets/hosted-synthesis"
  fakebin=$(make_fake_toolchain "$case_dir")
  expected="GBRAIN_SERVING_CREDENTIAL: this home serves its brain as the main brain and holds the hosted synthesis credential 'hosted-synthesis'; a read-only holder can reach think on it - remove the credential (and think.secret) before serving"

  for mode in 0 1; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      FM_BOOTSTRAP_DETECT_ONLY="$mode" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
      "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
    printf '%s\n' "$out" | grep -Fx "$expected" >/dev/null \
      || fail "detect-only=$mode: bootstrap must surface the serving-credential violation (got: $out)"
  done

  # Deleting the credential alone does not clear it: the shared plane still
  # points think off this host, and the key a served think spends is injected
  # into the synthesizing process rather than read from the credential plane.
  # Fail by: proving only "no credential named by think.secret".
  rm -f "$home/config/gbrain-secrets/hosted-synthesis"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "GBRAIN_SERVING_CREDENTIAL: " \
    "removing the credential file must not clear a serving home still pointed at a hosted think provider"
  assert_contains "$out" "api.example.invalid" \
    "the remaining diagnostic must name the hosted provider the think endpoint reaches"

  # jq is not in the universal toolchain, and its absence is a missing tool
  # rather than a corrupt configuration. Fail by: letting the shared-plane
  # validator's "not valid JSON" stand in for an interpreter that is not there.
  bash_env="$case_dir/no-jq.bash"
  cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  return 127
}
SH
  out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "GBRAIN_SERVING_CREDENTIAL: jq is not installed" \
    "a missing jq must be reported as the missing tool it is"
  assert_not_contains "$out" "gbrain.json is not valid JSON" \
    "a missing jq must never be reported as a corrupt configuration"

  # Both halves removed clears it, which is what makes the diagnostic a signal
  # rather than a permanent fixture of session start.
  printf '%s\n' '{"version":1}' > "$home/config/gbrain.json"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "GBRAIN_SERVING_CREDENTIAL:" \
    "bootstrap must clear the diagnostic once the serving home has no hosted synthesis at all"
  pass "bootstrap surfaces a serving-home credential violation in normal and detect-only sessions"
}

# FM_BOOTSTRAP_NETWORK splits one bootstrap run into its local and network
# halves so a session start can compose its digest from the local half alone and
# run the network half concurrently. The property that has to hold is that the
# split is a PARTITION: `skip` plus `only` together do exactly what `all` does,
# with no step dropped and no step run twice.
test_network_phase_partitions_the_run() {
  local case_dir fakebin bash_env all_out skip_out only_out combined
  case_dir="$TMP_ROOT/network-phase"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  # Break the two diagnostics that stand for the two halves: a local tool floor
  # and the network GitHub-auth probe.
  rm -f "$fakebin/node"
  bash_env="$case_dir/mask-node.bash"
  cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = node ]; then
    return 1
  fi
  builtin command "$@"
}
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh"

  all_out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$all_out" "MISSING: node (install:" "the unsplit run lost its local diagnostic"
  assert_contains "$all_out" "NEEDS_GH_AUTH" "the unsplit run lost its network diagnostic"

  skip_out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$skip_out" "MISSING: node (install:" "the local half lost its own diagnostic"
  assert_not_contains "$skip_out" "NEEDS_GH_AUTH" "the local half still made a network call"

  only_out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$only_out" "NEEDS_GH_AUTH" "the network half lost its own diagnostic"
  assert_not_contains "$only_out" "MISSING: node" "the network half repeated the local half's work"

  combined=$(printf '%s\n%s\n' "$skip_out" "$only_out" | LC_ALL=C sort)
  [ "$combined" = "$(printf '%s\n' "$all_out" | LC_ALL=C sort)" ] \
    || fail "skip + only is not the same set of findings as an unsplit run"$'\n'"all:      $all_out"$'\n'"skip:     $skip_out"$'\n'"only:     $only_out"

  # A typo must never silently drop a safety sweep, so anything unrecognized
  # resolves to the complete run.
  [ "$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=sikp "$ROOT/bin/fm-bootstrap.sh")" = "$all_out" ] \
    || fail "an unrecognized FM_BOOTSTRAP_NETWORK value did not fall back to the complete run"
  pass "bootstrap: FM_BOOTSTRAP_NETWORK partitions one run into local and network halves"
}

test_network_sweeps_recheck_lock_ownership() {
  local case_dir fakebin fake_root marker out
  case_dir="$TMP_ROOT/network-lock-handoff"
  mkdir -p "$case_dir/home/config" "$case_dir/home/projects" "$case_dir/home/state"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '222222\n' > "$case_dir/home/state/.lock"
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root="$case_dir/root"
  marker="$case_dir/fleet-sync.started"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:?}"
SH
  chmod +x "$fake_root/bin/fm-fleet-sync.sh"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$fake_root" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=111111 FM_FAKE_FLEET_SYNC_STARTED_MARKER="$marker" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_absent "$marker" "a stale worker refreshed project clones after lock handoff"
  assert_contains "$out" "changed before dead-secondmate relaunch" \
    "the stale worker did not report the refused liveness sweep"
  assert_contains "$out" "changed before secondmate convergence" \
    "the stale worker did not report the refused convergence sweep"
  assert_contains "$out" "changed before pending handoff delivery" \
    "the stale worker did not report the refused handoff sweep"
  assert_contains "$out" "changed before project clone refresh" \
    "the stale worker did not report the refused clone refresh"
  pass "bootstrap: every deferred mutating sweep rechecks fleet-lock ownership"
}

# The verdict costs three subprocesses, so a caller that already has it can hand
# it over - but only one hop, and never onward into a spawned agent's
# environment, where it could outlive a tasks-axi upgrade.
# assert_timing_record <log> <scope> <name> <detail> <msg>: one bin/fm-timing-lib.sh
# record with exactly these fields must exist. Field-exact rather than a substring
# match, so a detail that landed in the wrong column cannot pass.
assert_timing_record() {
  local log=$1 scope=$2 name=$3 detail=$4 msg=$5
  awk -F'\t' -v s="$scope" -v n="$name" -v d="$detail" '
    $1 == "v1" && $2 == s && $3 == n && $6 == d { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$log" || fail "$msg"$'\n'"$(cat "$log")"
}

# The deferred network stage publishes ONE started/finished pair, so a slow run
# used to be unattributable without re-running it by hand. These are the records
# that make it attributable, and they must come from the real sweeps rather than
# a stand-in: what is being pinned is that each network owner is actually wrapped.
# bin/fm-timing-lib.sh stays inert unless FM_TIMING_LOG names a file, so an
# ordinary bootstrap run is unaffected either way, which is asserted here too.
test_network_phases_record_per_step_elapsed_times() {
  local case_dir fakebin log fields
  case_dir="$TMP_ROOT/network-timings"
  mkdir -p "$case_dir/home/config" "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/projects"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' $$ > "$case_dir/home/state/.lock"
  fakebin=$(make_fake_toolchain "$case_dir")
  # A real clone with a real origin, so fm-fleet-sync.sh genuinely iterates it.
  fm_git_init_commit "$case_dir/home/projects/alpha"
  fm_git_add_origin "$case_dir/home/projects/alpha" "$case_dir/alpha-origin"
  # A secondmate the liveness sweep must account for. Whatever verdict it reaches
  # is owned elsewhere; what matters here is that the step is measured.
  fm_write_secondmate_meta "$case_dir/home/state/mate-a.meta" "$case_dir/home"

  log="$case_dir/timings.tsv"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ FM_TIMING_LOG="$log" FM_TIMING_EPOCH_MS=0 \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1

  assert_present "$log" "the network phase recorded no elapsed times at all"
  assert_timing_record "$log" phase gh-auth '' "the GitHub auth probe was not timed"
  assert_timing_record "$log" phase secondmate-liveness '' "the dead-secondmate relaunch sweep was not timed"
  assert_timing_record "$log" phase secondmate-sync '' "the secondmate convergence sweep was not timed"
  assert_timing_record "$log" phase handoff-delivery '' "the pending handoff sweep was not timed"
  assert_timing_record "$log" phase fleet-sync '' "the project clone refresh was not timed"
  assert_timing_record "$log" secondmate liveness mate-a \
    "the liveness sweep was not attributed to the individual secondmate it checked"
  assert_timing_record "$log" clone sync alpha \
    "the clone refresh was not attributed to the individual clone it refreshed"

  # Every record carries a start offset and an elapsed time, both numeric, so the
  # artifact can be read as a timeline rather than a bag of durations.
  fields=$(awk -F'\t' '$4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ { n++ } END { print n+0 }' "$log")
  [ "$fields" = "$(grep -c . "$log")" ] \
    || fail "some records lack a numeric start offset and elapsed time: $(cat "$log")"

  # And an ordinary run - the local half, or any caller that never asked for
  # timings - writes nothing anywhere.
  rm -f "$log"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_absent "$log" "a run that never asked for timings recorded them anyway"
  pass "bootstrap: each deferred network phase, secondmate, and clone records its own elapsed time"
}

# A board is decoration over work that already exists, so a board firstmate
# cannot reach must cost the fleet nothing at all: the rest of the network phase
# still runs and still reports, and the session start is not handed a diagnostic
# about a transient host it will simply retry at its next interval.
test_a_board_problem_never_becomes_a_fleet_problem() {
  local case_dir fakebin log out rc
  case_dir="$TMP_ROOT/board-sweep"
  mkdir -p "$case_dir/home/config" "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/projects"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' "$$" > "$case_dir/home/state/.lock"
  {
    printf '# Projects\n\n'
    printf -- '- widget [no-mistakes tracker=github:github.com/acme/widget board=https://github.com/users/captain/projects/7] - fixture (added 2026-08-18)\n'
  } > "$case_dir/home/data/projects.md"
  fakebin=$(make_fake_toolchain "$case_dir")
  # Every board call refuses. `gh auth status` still succeeds, so the only thing
  # broken in this run is the board.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  echo "gh: the board is unreachable" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  fm_git_init_commit "$case_dir/home/projects/alpha"
  fm_git_add_origin "$case_dir/home/projects/alpha" "$case_dir/alpha-origin"

  log="$case_dir/timings.tsv"
  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ FM_TIMING_LOG="$log" FM_TIMING_EPOCH_MS=0 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  rc=$?
  set -e
  expect_code 0 "$rc" "an unreachable board failed the whole network phase"
  assert_timing_record "$log" phase board-sweep '' "the board sweep never ran"
  assert_timing_record "$log" phase fleet-sync '' "the clone refresh was lost when the board refused"
  assert_not_contains "$out" "BOARD_SWEEP:" "a transient board failure became a session-start diagnostic"
  assert_present "$case_dir/home/state/.board-sweep" "the sweep did not record its interval"

  # And a home whose projects declare no board contacts no host at all, which is
  # every home until the captain adds the token by hand.
  rm -rf "$case_dir/home/state/.board-sweep"
  printf -- '- widget [no-mistakes tracker=github:github.com/acme/widget] - fixture (added 2026-08-18)\n' \
    >> "$case_dir/home/data/projects.md.undeclared"
  mv "$case_dir/home/data/projects.md.undeclared" "$case_dir/home/data/projects.md"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_absent "$case_dir/home/state/.board-sweep" "a home that declares no board still swept one"
  pass "bootstrap: an unreachable board costs the fleet nothing, and an undeclared home sweeps nothing"
}

test_tasks_axi_verdict_handoff_is_consumed_once() {
  local case_dir fakebin log out
  case_dir="$TMP_ROOT/tasks-axi-handoff"
  mkdir -p "$case_dir/home/config"
  fakebin=$(make_fake_toolchain "$case_dir")
  log="$case_dir/tasks-axi.log"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TASKS_AXI_LOG:?}"
printf '0.0.1\n'
exit 0
SH
  chmod +x "$fakebin/tasks-axi"

  # Without the handoff, the incompatible stub is probed and reported.
  : > "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: tasks-axi (install:" "the unaided run did not probe tasks-axi"
  assert_grep '--version' "$log" "the unaided run never ran the probe"

  # With it, the probe is skipped entirely and the handed-in verdict is used.
  : > "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TASKS_AXI_COMPATIBLE=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: tasks-axi" "the handed-in verdict was ignored"
  [ ! -s "$log" ] || fail "the handed-in verdict did not save the probe: $(cat "$log")"

  # A malformed value is not a verdict.
  : > "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TASKS_AXI_COMPATIBLE=yes "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: tasks-axi (install:" "a malformed handoff value was trusted"

  # And the handoff never reaches a grandchild: bootstrap spawns agents, and a
  # verdict cached into an agent's environment would outlive the tool it describes.
  out=$(FM_TASKS_AXI_COMPATIBLE=1 bash -c '. "$1"; printf "%s\n" "${FM_TASKS_AXI_COMPATIBLE-unset}"' \
    _ "$ROOT/bin/fm-tasks-axi-lib.sh")
  [ "$out" = unset ] || fail "sourcing the library left the handoff in the environment: $out"
  pass "bootstrap: the tasks-axi compatibility verdict travels exactly one process hop"
}

test_crew_dispatch_active_rules_are_verbose_bootstrap_info() {
  local case_dir fakebin out expect
  case_dir="$TMP_ROOT/dispatch-active"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"rules":[{"when":"fresh news","use":{"harness":"grok"},"why":"current context"},{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]},{"when":"legacy feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"quota-balanced"}],"default":[{"harness":"pi","model":"anthropic/claude-sonnet-5","effort":"high"},{"harness":"grok","model":"grok-4.5","effort":"high"}]}' > "$case_dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "active dispatch profile should be silent by default, got: $out"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")

  expect=$'BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json\nBOOTSTRAP_INFO: crew dispatch rule: fresh news -> grok\nBOOTSTRAP_INFO: crew dispatch rule: big feature -> quota-balanced[claude/claude-sonnet-5/high, codex/gpt-5.5/high]\nBOOTSTRAP_INFO: crew dispatch rule: legacy feature -> quota-balanced[claude, codex]\nBOOTSTRAP_INFO: crew dispatch default: quota-balanced[pi/anthropic/claude-sonnet-5/high, grok/grok-4.5/high]'
  [ "$out" = "$expect" ] || fail "active dispatch verbose info block mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "bootstrap surfaces active crew-dispatch rules only as verbose BOOTSTRAP_INFO"
}

test_crew_dispatch_backend_mismatch() {
  # S2: a valid cursor/agy dispatch profile on a NON-herdr backend is unusable
  # (every matching task is refused at spawn), so bootstrap must diagnose it here
  # rather than deferring the surprise to task intake. On herdr it stays silent.
  local case_dir fakebin out h
  for h in cursor agy; do
    case_dir="$TMP_ROOT/dispatch-mismatch-$h"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' tmux > "$case_dir/home/config/backend"
    printf '{"rules":[{"when":"paid sub work","use":{"harness":"%s","model":"m1"}}]}\n' "$h" \
      > "$case_dir/home/config/crew-dispatch.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    printf '%s\n' "$out" | grep -q "CREW_DISPATCH: backend mismatch" \
      || fail "$h on tmux backend should warn of a backend mismatch, got: $out"
    printf '%s\n' "$out" | grep -q "($h)" \
      || fail "$h backend-mismatch warning should name the harness, got: $out"

    # Same config on herdr must NOT warn of a mismatch (cursor/agy are usable there).
    printf '%s\n' herdr > "$case_dir/home/config/backend"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
    printf '%s\n' "$out" | grep -q "CREW_DISPATCH: backend mismatch" \
      && fail "$h on the herdr backend must NOT warn of a backend mismatch, got: $out"
  done
  pass "bootstrap warns when a cursor/agy dispatch profile is configured on a non-herdr backend"
}

test_crew_dispatch_validation() {
  local label body expect mode case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/dispatch-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/crew-dispatch.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)" ;;
    esac
  done <<'ROWS'
malformed dispatch config is flagged^{"rules":[^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON
unverified dispatch harness is flagged^{"rules":[{"when":"anything","use":{"harness":"spaceship"}}],"default":{"harness":"codex"}}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: spaceship
unsupported codex max effort is flagged^{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
unsupported grok max effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:max
unsupported grok xhigh effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"xhigh"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:xhigh
pi max effort is accepted^{"rules":[{"when":"deep coding","use":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"max"}}]}^empty^
pi-signed max effort is accepted^{"rules":[{"when":"signed coding","use":{"harness":"pi-signed","model":"openai-codex/gpt-5.6-sol","effort":"max"}}]}^empty^
muse shared efforts are accepted^{"rules":[{"when":"muse low","use":{"harness":"muse","effort":"low"}},{"when":"muse medium","use":{"harness":"muse","effort":"medium"}},{"when":"muse high","use":{"harness":"muse","effort":"high"}},{"when":"muse xhigh","use":{"harness":"muse","effort":"xhigh"}},{"when":"muse max","use":{"harness":"muse","effort":"max"}}]}^empty^
unsupported muse ultra effort is flagged^{"rules":[{"when":"muse ultra","use":{"harness":"muse","effort":"ultra"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: muse:ultra
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
unsupported cursor effort is flagged^{"rules":[{"when":"composer work","use":{"harness":"cursor","model":"composer-2.5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: cursor:high
unsupported agy max effort is flagged^{"rules":[{"when":"gemini work","use":{"harness":"agy","model":"gemini-3-pro","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: agy:max
kimi model profile is accepted^{"rules":[{"when":"kimi work","use":{"harness":"kimi","model":"kimi-code/k3"}}]}^empty^
unsupported kimi effort is flagged^{"rules":[{"when":"kimi work","use":{"harness":"kimi","model":"kimi-code/k3","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: kimi:high
array use with quota-balanced is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}],"select":"quota-balanced"}]}^empty^
array use without select is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}]}]}^empty^
one-element array use is accepted^{"rules":[{"when":"focused feature","use":[{"harness":"claude"}]}]}^empty^
default array is accepted^{"default":[{"harness":"pi","model":"anthropic/claude-sonnet-5"},{"harness":"grok"}]}^empty^
one-element default array is accepted^{"default":[{"harness":"codex"}]}^empty^
empty array use is flagged^{"rules":[{"when":"big feature","use":[]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each rule needs at least one use profile
array profile without harness is flagged^{"rules":[{"when":"big feature","use":[{"model":"gpt-5.5"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each use profile needs harness
array profile with malformed model is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","model":5}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - use profile model and effort must be non-empty strings when present
unknown select is flagged^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"mystery"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unknown select: mystery
array profile unsupported effort is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","effort":"max"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
empty default array is flagged^{"default":[]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default needs at least one profile
non-object default array entry is flagged^{"default":["codex"]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile must be an object
default array profile without harness is flagged^{"default":[{"model":"gpt-5.5"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile needs harness
default array malformed effort is flagged^{"default":[{"harness":"codex","effort":3}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default profile model and effort must be non-empty strings when present
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

test_bootstrap_reporting
test_no_mistakes_min_version
test_gh_axi_min_version
test_lavish_axi_min_version
test_tasks_axi_min_version
test_quota_axi_min_version
test_git_is_required_with_supported_install_instruction
test_orca_backend_gates_orca_tool_only_when_selected
test_session_provider_backends_do_not_require_tmux
test_session_provider_backends_gate_own_cli_not_tmux
test_herdr_install_requires_manual_action
test_cmux_bundled_cli_satisfies_dependency
test_unknown_backend_reports_invalid_configuration
test_json_backends_require_jq_not_tmux
test_treehouse_lease_check_follows_resolved_backend
test_fleet_sync_timeout_scales_with_origin_backed_project_count
test_fleet_sync_timeout_floor_preserves_small_fleets
test_fleet_sync_timeout_explicit_override_wins
test_fleet_sync_timeout_empty_override_uses_default
test_fleet_sync_timeout_is_computed_before_launch
test_usage_store_refresh_is_gated_on_an_existing_store
test_usage_store_refresh_skips_a_detect_only_session
test_usage_store_refresh_reports_its_timeout
test_usage_store_refresh_falls_back_from_a_zero_bound
test_usage_store_refresh_reports_a_collector_that_failed
test_usage_store_refresh_uses_bash_fallback
test_routine_bootstrap_confirmations_are_silent
test_routine_bootstrap_contract_runs_under_system_bash
test_bootstrap_relays_vault_drift_in_both_modes
test_bootstrap_relays_gbrain_serving_credential_in_both_modes
test_network_phase_partitions_the_run
test_network_sweeps_recheck_lock_ownership
test_network_phases_record_per_step_elapsed_times
test_a_board_problem_never_becomes_a_fleet_problem
test_tasks_axi_verdict_handoff_is_consumed_once
test_crew_dispatch_active_rules_are_verbose_bootstrap_info
test_crew_dispatch_backend_mismatch
test_crew_dispatch_validation
printf '\nall fm-bootstrap tests passed\n'
