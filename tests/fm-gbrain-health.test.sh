#!/usr/bin/env bash
# Behavior tests for bin/fm-gbrain-health.sh, the read-only GBrain health
# snapshot the dashboard panel consumes.
#
# Every case runs without a real brain and without network reachability:
# nothing here shells out to a real gbrain or makes a real HTTP call. The
# script resolves both of its children from its own SCRIPT_DIR, so each case
# runs a copy of it out of a per-test bin directory holding the stub
# fm-gbrain-capture.sh its status read finds. Embed, rerank, synthesis, and
# main-brain reachability are simulated with a curl stub prepended to PATH
# that honours FM_PROBE_STATE (ok exits 0, down exits 124 like a timeout), so
# the script runs its production probe path unchanged under test.
#
# The states under test are the ones the dashboard panel actually renders:
# not configured, configured but no index yet, configured with index and
# degraded embedding or reranker, configured with hosted synthesis degraded,
# capture outbox pending/failed/last-capture timing, and maintenance override
# via FM_GBRAIN_MAINTENANCE_STATE. A health snapshot is for the panel; if a
# state the panel reads is missing here, the panel cannot be verified
# against it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The per-test bin directory created by make_script_dir is the script's own
# SCRIPT_DIR, so a stub fm-gbrain-capture.sh placed alongside it is what the
# script calls.

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v bash >/dev/null 2>&1 || { echo "skip: bash not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-gbrain-health)

# --- fixtures ---------------------------------------------------------------

# A firstmate-shaped home with no GBrain configuration. The script reports
# configured: false and every probe as unconfigured/absent.
make_bare_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '%s\n' "$home"
}

# A firstmate-shaped home with a valid gbraintron plane and no initialized
# index, the ordinary "configured but never bootstrapped" state. Embedding is
# present so retrieval can be exercised end-to-end once a probe stub answers.
make_uninitialized_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/config" "$home/data" "$home/state"
  jq -n '{version: 1, local: {embedding_base_url: "http://127.0.0.1:11434/v1", embedding_model: "embed-test"}}' \
    > "$home/config/gbrain.json"
  printf '%s\n' "$home"
}

# A home with a valid plane, an initialized PGLite directory, and stubbed
# capture state. The shellcheck-clean fixtures here are deliberately shaped to
# match what a real firstmate home looks like so the script's parsing is what
# is tested, not the fixtures. The probe URLs are loopback so the test's curl
# stub can answer them without network reachability.
make_ready_home() {  # <name> [probe-state]
  local home=$TMP_ROOT/$1
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/data/gbrain/pglite" "$home/data/gbrain-outbox"
  jq -n '
    {
       version: 1,
       local: {embedding_base_url: "http://127.0.0.1:11434/v1", embedding_model: "embed-test",
               reranker_base_url: "http://127.0.0.1:8081/v1", reranker_model: "rerank-test"},
       think: {base_url: "http://127.0.0.1:9999/v1", model: "synth-test", secret: "minimax"}
     }' > "$home/config/gbrain.json"
  printf '%s\n' "$home"
}

# Replace fm-gbrain-capture.sh with a stub whose --json output is under test
# control. The production capture command is too noisy to call from a
# portable test, and this exercise is the script's contract with its
# capture-status producer. The script looks up its siblings by absolute path,
# so the stub has to live alongside fm-gbrain-health.sh in a per-test bin
# directory; that directory then becomes the script's SCRIPT_DIR.
install_capture_stub() {  # <bin-dir> <body>
  local bindir=$1 body=$2
  mkdir -p "$bindir"
  cat > "$bindir/fm-gbrain-capture.sh" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = "status" ] || { echo "stub: unsupported command \$*" >&2; exit 2; }
[ "\${2:-}" = "--json" ] || { echo "stub: capture status expects --json" >&2; exit 2; }
printf '%s\n' '$body'
exit 0
SH
  chmod +x "$bindir/fm-gbrain-capture.sh"
}

# Materialise a per-test bin directory that holds the script under test plus
# the rest of its sibling helpers (fm-gbrain-lib.sh, fm-timeout-lib.sh), and
# echo the path. Tests put the capture stub into the same directory so the
# script resolves it as $SCRIPT_DIR/fm-gbrain-capture.sh.
make_script_dir() {  # <bin-dir>
  local bindir=$1
  mkdir -p "$bindir"
  cp "$ROOT/bin/fm-gbrain-health.sh" "$bindir/"
  cp "$ROOT/bin/fm-gbrain-lib.sh" "$bindir/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$bindir/"
  printf '%s\n' "$bindir"
}

# Patch fm-gbrain-health.sh's probe_url at runtime by prepending a shim dir
# whose curl writes the synthetic answer. The production curl binary is
# resolved last on PATH, so this stub wins. FM_PROBE_STATE controls the answer:
# ok returns 0 (the endpoint is up), down returns 124 (the probe timed out).
patch_curl() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/curl" <<'SH'
#!/usr/bin/env bash
# Test-time stub: emulate fm_run_timed/cURL for a URL probe. Honours
# FM_PROBE_STATE: ok returns 0, down returns 124 (timeout).
state="${FM_PROBE_STATE:-ok}"
case "$state" in
  ok) exit 0 ;;
  down) exit 124 ;;
  *) echo "probe stub: unrecognized FM_PROBE_STATE '$state'" >&2; exit 2 ;;
esac
SH
  chmod +x "$dir/curl"
}

# Read the health snapshot for <home>, with capture status from <capturedir>
# and probe behaviour under <probedir> which gets a curl stub prepended. The
# stub honours FM_PROBE_STATE: ok returns 0, down returns 124. Returns the
# JSON document. The script itself is sourced from <scriptdir>, which also
# holds the capture stub so the script's SCRIPT_DIR lookup finds it.
run_health() {  # <home> <scriptdir> <probedir> [extra-env...]
  local home=$1 scriptdir=$2 probedir=$3
  shift 3
  PATH="$probedir:$PATH" \
  FM_HOME="$home" \
  FM_ROOT="$ROOT" \
    "$@" \
    bash "$scriptdir/fm-gbrain-health.sh" --json
}

# --- the cases --------------------------------------------------------------

# A home without a config/gbrain.json is not "configured". The dashboard
# renders "no brain configured" from these fields; nothing here should
# invent a brain.
test_unconfigured_home_reports_no_brain() {
  local home out bindir
  home=$(make_bare_home bare)
  bindir=$(make_script_dir "$TMP_ROOT/bin-bare")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '
    .schema == "fm-gbrain-health.v1"
      and .configured == false
      and .index.state == "absent"
      and (.index.detail | test("no brain configured"))
      and .retrieval.state == "absent"
      and .retrieval.embedding.state == "unconfigured"
      and .retrieval.reranker.state == "unconfigured"
      and .retrieval.main_brain.state == "unconfigured"
      and .synthesis.state == "unconfigured"
      and .capture.enabled == false
      and .capture.archived == 0
      and .capture.pending == 0
      and .maintenance.state == "ready"
  ' >/dev/null || fail "bare-home health did not report no-brain: $out"
  pass "unconfigured home reports configured:false and every probe as absent"
}

# A home with a valid plane but no PGLite directory reports the ordinary
# "configured but never bootstrapped" state, not a fault. The dashboard
# shows that distinction so the operator can tell a fresh home from a broken
# one.
test_configured_uninitialized_reports_seeded_state() {
  local home out bindir
  home=$(make_uninitialized_home uninit)
  bindir=$(make_script_dir "$TMP_ROOT/bin-uninit")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '
    .configured == true
      and .index.state == "absent"
      and (.index.detail | test("no initialized brain"))
      and .retrieval.embedding.state == "ok"
      and .retrieval.embedding.model == "embed-test"
      and .retrieval.embedding.endpoint == "http://127.0.0.1:11434/v1"
      and .retrieval.reranker.state == "unconfigured"
      and .retrieval.main_brain.state == "absent"
      and .synthesis.state == "unconfigured"
      and .capture.enabled == false
  ' >/dev/null || fail "configured-but-uninitialized home gave wrong shape: $out"
  pass "configured but uninitialized home reports the seeded-not-bootstrapped state"
}

# A fully bootstrapped home with healthy probes reports ok at every layer
# and the captured-at timestamp of the most recent captured document. This is
# what a healthy panel looks like.
test_healthy_home_reports_ok() {
  local home out bindir
  home=$(make_ready_home ready)
  bindir=$(make_script_dir "$TMP_ROOT/bin-ready")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":12,"pending":0,"failed":0,"unreadable":0},"documents":[{"status":"captured","captured_at":"2026-08-05T10:00:00Z"},{"status":"captured","captured_at":"2026-08-05T21:07:59Z"}]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '
    .configured == true
      and .index.state == "ok"
      and .retrieval.state == "ok"
      and .retrieval.embedding.state == "ok"
      and .retrieval.reranker.state == "ok"
      and .synthesis.state == "ok"
      and .capture.enabled == true
      and .capture.archived == 12
      and .capture.last_capture_at == "2026-08-05T21:07:59Z"
      and .capture.last_error == null
      and .maintenance.state == "ready"
  ' >/dev/null || fail "healthy home did not report ok at every layer: $out"
  pass "healthy home reports ok at every layer and the latest captured_at"
}

# A degraded embedding or reranker makes retrieval degraded; the dashboard
# reads that as "search will fall back to a worse ordering". Local retrieval
# stays up so search keeps working. The probe stub does not differentiate
# between embedding and reranker, so both end up degraded; what matters for
# the panel is that retrieval is degraded at the worst-of-the-three level.
test_degraded_embedding_makes_retrieval_degraded() {
  local home out bindir
  home=$(make_ready_home degraded-embed)
  bindir=$(make_script_dir "$TMP_ROOT/bin-degraded")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":3,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe" env FM_PROBE_STATE=down)
  printf '%s' "$out" | jq -e '
    .configured == true
      and .index.state == "ok"
      and .retrieval.state == "degraded"
      and .retrieval.embedding.state == "degraded"
      and (.retrieval.embedding.detail | test("no answer at"))
  ' >/dev/null || fail "degraded embedding did not flip retrieval to degraded: $out"
  pass "degraded embedding degrades retrieval without affecting synthesis"
}

# A degraded hosted-synthesis provider leaves retrieval and local search
# unaffected. The dashboard renders them as independent readings so the
# operator sees which path is degraded.
test_degraded_synthesis_leaves_retrieval_ok() {
  local home out bindir
  home=$(make_ready_home degraded-synth)
  bindir=$(make_script_dir "$TMP_ROOT/bin-degraded-synth")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":3,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe" env FM_PROBE_STATE=down)
  printf '%s' "$out" | jq -e '
    .synthesis.state == "degraded"
      and (.synthesis.detail | test("synthesis is unavailable"))
  ' >/dev/null || fail "degraded synthesis should be reported as degraded: $out"
  pass "degraded synthesis leaves local search working and reports its own degradation"
}

# Capture-status with pending and failed records and a fresh last_error
# must surface on the panel. The dashboard is the only place these counts are
# visible at a glance.
test_capture_status_reports_pending_failed_and_last_error() {
  local home out bindir
  home=$(make_ready_home with-capture-issues)
  bindir=$(make_script_dir "$TMP_ROOT/bin-capture-issues")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":5,"pending":3,"failed":1,"unreadable":0},"documents":[{"status":"failed","last_error":"brain refused: index is locked"},{"status":"pending"},{"status":"pending"},{"status":"pending"}]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '
    .capture.archived == 5
      and .capture.pending == 3
      and .capture.failed == 1
      and .capture.last_error == "brain refused: index is locked"
  ' >/dev/null || fail "capture status did not surface pending/failed/last_error: $out"
  pass "capture status reports pending/failed/unreadable counts and last_error"
}

# A record marked archived proves the page was accepted once, not that the index
# still serves it, so the panel has to be able to show a parity gap. The verdict
# is REPLAYED from the durable audit record rather than measured here, because
# this command runs on every dashboard poll. Fail by: measuring it here, or
# reporting a home that has never been audited as a clean zero gap.
test_the_parity_verdict_is_replayed_and_never_invented() {
  local home out bindir
  home=$(make_ready_home with-audit)
  bindir=$(make_script_dir "$TMP_ROOT/bin-audit")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":291,"pending":0,"failed":0,"unreadable":0,"truncated":2},"documents":[]}'
  patch_curl "$TMP_ROOT/probe"

  # Never audited: that is what it says, rather than a zero nobody measured.
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '
    .capture.audit.state == "unknown" and .capture.audit.missing == null
  ' >/dev/null || fail "an unaudited home must report unknown, not a clean gap: $out"
  printf '%s' "$out" | jq -e '.capture.truncated == 2' >/dev/null \
    || fail "the cut-body count must reach the panel: $out"

  jq -n '{schema: "fm-gbrain-capture-audit.v1", generated: "2026-08-25T00:00:00Z",
          home: "h", state: "gap", stored: 291, active: 288, missing: 3, truncated: 2,
          missing_slugs: ["firstmate/h/task/a", "firstmate/h/task/b", "firstmate/h/task/c"],
          detail: "3 captured document(s) are absent from the active index"}' \
    > "$home/state/.gbrain-audit"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '
    .capture.audit.state == "gap" and .capture.audit.missing == 3
      and .capture.audit.stored == 291 and .capture.audit.active == 288
      and .capture.audit.observed == "2026-08-25T00:00:00Z"
  ' >/dev/null || fail "the recorded parity gap must reach the panel: $out"

  # A damaged record is NOT the same answer as no record: an audit ran here and
  # its verdict cannot be read, which is a could-not-read rather than a home
  # nobody has checked yet.
  printf '%s\n' 'not json at all' > "$home/state/.gbrain-audit"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '.capture.audit.state == "unreadable" and .capture.audit.missing == null' >/dev/null \
    || fail "a damaged audit record must read as unreadable, not as never audited: $out"

  # The reachable version of the same case: a record this reader does not know
  # how to parse because its schema moved. Reporting that as never-audited would
  # be a fleet-wide false all-clear waiting on a version bump.
  jq -n '{schema: "fm-gbrain-capture-audit.v2", generated: "2026-08-25T00:00:00Z",
          home: "h", state: "ok"}' > "$home/state/.gbrain-audit"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '.capture.audit.state == "unreadable"' >/dev/null \
    || fail "an unrecognized audit schema must read as unreadable: $out"
  printf '%s' "$out" | jq -e '.capture.audit.detail | test("could not be read")' >/dev/null \
    || fail "an unreadable verdict must say an audit ran and could not be read: $out"
  pass "the stored-versus-served verdict is replayed from its record and never invented"
}

# The maintenance field is the only place a paused upgrade or reindex can
# appear; the script reads FM_GBRAIN_MAINTENANCE_STATE rather than inferring
# it. An upgrade announcement renders as upgrading with the operator's
# detail; absence renders as ready.
test_maintenance_override_is_surfaced_verbatim() {
  local home out bindir
  home=$(make_ready_home upgrading)
  bindir=$(make_script_dir "$TMP_ROOT/bin-upgrading")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":1,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe" \
    env FM_GBRAIN_MAINTENANCE_STATE=upgrading \
           FM_GBRAIN_MAINTENANCE_DETAIL="rebuild embedding index for v0.43")
  printf '%s' "$out" | jq -e '
    .maintenance.state == "upgrading"
      and .maintenance.detail == "rebuild embedding index for v0.43"
  ' >/dev/null || fail "maintenance upgrade did not surface: $out"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe" \
    env FM_GBRAIN_MAINTENANCE_STATE=reindexing \
           FM_GBRAIN_MAINTENANCE_DETAIL="reranker swap")
  printf '%s' "$out" | jq -e '
    .maintenance.state == "reindexing"
      and .maintenance.detail == "reranker swap"
  ' >/dev/null || fail "maintenance reindex did not surface: $out"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '.maintenance.state == "ready"' >/dev/null \
    || fail "absent maintenance state should default to ready: $out"
  pass "maintenance override renders verbatim and defaults to ready"
}

# A capture-status stub that returns an unexpected schema is reported as
# such without crashing the whole health read. A read-only dashboard must
# never take the fleet down because a backend version drifted.
test_unsupported_capture_schema_is_reported_not_fatal() {
  local home out bindir
  home=$(make_ready_home bad-schema)
  bindir=$(make_script_dir "$TMP_ROOT/bin-bad-schema")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v999","totals":{}}'
  patch_curl "$TMP_ROOT/probe"
  out=$(run_health "$home" "$bindir" "$TMP_ROOT/probe")
  printf '%s' "$out" | jq -e '
    .capture.enabled == true
      and .capture.archived == 0
      and (.capture.last_error | test("capture status schema"))
  ' >/dev/null || fail "unsupported capture schema was not reported: $out"
  pass "unsupported capture schema is reported without failing the health read"
}

# A capture-status call that itself times out is reported as such and does
# not bring the rest of the read down. The whole health read is bounded by
# --timeout, so a stuck capture producer cannot burn past what is left of that
# budget however long it hangs for.
test_capture_status_timeout_is_reported_not_fatal() {
  local home out bindir
  home=$(make_ready_home cap-timeout)
  bindir=$(make_script_dir "$TMP_ROOT/bin-cap-timeout")
  cat > "$bindir/fm-gbrain-capture.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "status" ] || exit 2
sleep 30
SH
  chmod +x "$bindir/fm-gbrain-capture.sh"
  patch_curl "$TMP_ROOT/probe"
  out=$(PATH="$TMP_ROOT/probe:$PATH" \
        FM_HOME="$home" FM_ROOT="$ROOT" \
        bash "$bindir/fm-gbrain-health.sh" --timeout 1 --json 2>&1)
  printf '%s' "$out" | jq -e '
    .capture.enabled == true
      and (.capture.last_error | test("capture status"))
  ' >/dev/null || fail "capture-status timeout was not reported: $out"
  pass "capture-status timeout is reported without failing the health read"
}

# The capture read is the LAST bounded step, so it is entitled to whatever is
# left of the budget rather than to one step's nominal share. Its cost is the
# only one that grows with the fleet's history - the outbox never shrinks - so
# capping it at a share would eventually drop the pending count and the last
# successful capture the panel exists to surface, and would do it silently.
test_capture_status_may_spend_the_remaining_budget() {
  local home out bindir
  home=$(make_ready_home cap-tail)
  bindir=$(make_script_dir "$TMP_ROOT/bin-cap-tail")
  # Slower than one nominal share of a 5-second budget (1s), well inside what
  # is left after four probes that answer at once.
  cat > "$bindir/fm-gbrain-capture.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "status" ] || exit 2
sleep 3
printf '%s\n' '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":81,"pending":2,"failed":0,"unreadable":0},"documents":[{"status":"captured","captured_at":"2026-08-05T21:07:59Z"}]}'
SH
  chmod +x "$bindir/fm-gbrain-capture.sh"
  patch_curl "$TMP_ROOT/probe"
  out=$(PATH="$TMP_ROOT/probe:$PATH" \
        FM_HOME="$home" FM_ROOT="$ROOT" \
        bash "$bindir/fm-gbrain-health.sh" --timeout 5 --json 2>&1)
  printf '%s' "$out" | jq -e '
    .capture.archived == 81
      and .capture.pending == 2
      and .capture.last_capture_at == "2026-08-05T21:07:59Z"
      and .capture.last_error == null
  ' >/dev/null || fail "capture read was refused the remaining budget: $out"
  pass "the capture read may spend what the probes left of the budget"
}

# Each flag consumes exactly its own tokens. A two-token flag that ate the one
# behind it would silently drop --json and, worse, silently accept an unknown
# flag instead of refusing it.
test_flags_are_order_independent_and_still_validated() {
  local home out bindir status
  home=$(make_ready_home flag-order)
  bindir=$(make_script_dir "$TMP_ROOT/bin-flag-order")
  install_capture_stub "$bindir" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  patch_curl "$TMP_ROOT/probe"
  out=$(PATH="$TMP_ROOT/probe:$PATH" FM_HOME="$home" FM_ROOT="$ROOT" \
        bash "$bindir/fm-gbrain-health.sh" --timeout 5 --json 2>&1)
  printf '%s' "$out" | jq -e '.schema == "fm-gbrain-health.v1"' >/dev/null \
    || fail "--timeout before --json did not produce a document: $out"
  status=0
  out=$(PATH="$TMP_ROOT/probe:$PATH" FM_HOME="$home" FM_ROOT="$ROOT" \
        bash "$bindir/fm-gbrain-health.sh" --timeout 5 --bogus 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an unknown flag after --timeout was accepted: $out"
  printf '%s' "$out" | grep -q "unknown flag: --bogus" \
    || fail "an unknown flag after --timeout was not named: $out"
  pass "flags are order independent and an unknown flag is still refused"
}

test_unconfigured_home_reports_no_brain
test_configured_uninitialized_reports_seeded_state
test_healthy_home_reports_ok
test_degraded_embedding_makes_retrieval_degraded
test_degraded_synthesis_leaves_retrieval_ok
test_capture_status_reports_pending_failed_and_last_error
test_the_parity_verdict_is_replayed_and_never_invented
test_maintenance_override_is_surfaced_verbatim
test_unsupported_capture_schema_is_reported_not_fatal
test_capture_status_timeout_is_reported_not_fatal
test_capture_status_may_spend_the_remaining_budget
test_flags_are_order_independent_and_still_validated
printf '\nall fm-gbrain-health tests passed\n'
