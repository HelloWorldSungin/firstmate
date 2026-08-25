#!/usr/bin/env bash
# Behavior tests for capturing finished task knowledge into a home's own brain:
# bin/fm-gbrain-capture.sh, bin/fm-gbrain-capture-lib.sh, and the teardown step
# that runs between publishing the durable manifest and removing volatile state.
#
# The two claims worth proving are the ones that pull against each other:
# capture must not be lossy, and teardown must never be blocked by it. So these
# tests stop the brain mid-teardown, hang it past the timeout, truncate an
# outbox record, and check every time that no task work is lost and no cleanup
# is delayed. The third claim is that a secret never reaches disk at all, which
# is proved against the OUTBOX file rather than only against what was delivered.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CAPTURE="$ROOT/bin/fm-gbrain-capture.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-capture)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- fixtures ---------------------------------------------------------------

# A home with an initialized brain unless --no-brain is given. The fake gbrain
# stores each delivered page under pages/<slug with / replaced>, which is what
# lets a test assert that two deliveries of one document produced ONE page.
make_home() {  # <name> [--no-brain]
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin" "$home/pages"
  [ "${2:-}" = --no-brain ] || mkdir -p "$home/data/gbrain/pglite"
  touch "$home/state/.last-watcher-beat"
  fake_gbrain "$home" ok
  printf '%s\n' "$home"
}

# mode ok: record the page and print its slug. hang: never return.
# fail: refuse with a message. missing: no gbrain on PATH at all.
# slow: behave as ok, but only after a delay long enough that two whole-second
# timestamps taken around it must differ.
fake_gbrain() {  # <home> <mode>
  local home=$1 mode=$2
  case $mode in
    missing) rm -f "$home/fakebin/gbrain"; return 0 ;;
    hang)
      cat > "$home/fakebin/gbrain" <<'SH'
#!/usr/bin/env bash
sleep 120
SH
      ;;
    fail)
      cat > "$home/fakebin/gbrain" <<'SH'
#!/usr/bin/env bash
echo "brain refused: index is locked by another writer" >&2
exit 1
SH
      ;;
    ok | slow)
      cat > "$home/fakebin/gbrain" <<SH
#!/usr/bin/env bash
set -u
$([ "$mode" = slow ] && printf 'sleep 2')
SH
      cat >> "$home/fakebin/gbrain" <<'SH'
# The audit reads the index's page listing, so the stub answers `list` from the
# pages it has actually stored: deleting a page file is then exactly what a
# soft-delete looks like from outside, which is the whole case being tested.
if [ "${1:-}" = list ]; then
  [ -n "${FM_TEST_PAGES:-}" ] || { echo "the fake brain needs FM_TEST_PAGES" >&2; exit 3; }
  for page in "$FM_TEST_PAGES"/*.md; do
    [ -e "$page" ] || continue
    page=${page##*/}
    slug=$(printf '%s' "${page%.md}" | tr '_' '/')
    # A listing can drop a page the index still serves, and it can answer with
    # rows nothing recognizes as a slug. Both look identical to a page that is
    # gone, which is the whole reason a gap may not rest on this listing.
    case "${FM_TEST_LIST_OMIT:-}" in '') ;; *) case "$slug" in *"$FM_TEST_LIST_OMIT"*) continue ;; esac ;; esac
    if [ -n "${FM_TEST_LIST_GARBLE:-}" ]; then
      printf 'row without any tab-separated slug\n'
    else
      printf '%s\tfirstmate-task\t2026-08-25\ttitle\n' "$slug"
    fi
  done
  exit 0
fi
# A direct read is what a reported gap actually rests on, so the stub answers
# `get` from the same stored pages and refuses a page it does not have with its
# own distinct status, the way a real not-found differs from a real error.
if [ "${1:-}" = get ]; then
  [ -n "${FM_TEST_PAGES:-}" ] || { echo "the fake brain needs FM_TEST_PAGES" >&2; exit 3; }
  page="$FM_TEST_PAGES/$(printf '%s' "${2:-}" | tr '/' '_').md"
  if [ -f "$page" ] && [ -z "${FM_TEST_GET_BROKEN:-}" ]; then cat "$page"; exit 0; fi
  [ -z "${FM_TEST_GET_BROKEN:-}" ] || { echo "the index is locked by another writer" >&2; exit 7; }
  echo "no such page: ${2:-}" >&2
  exit 4
fi
[ "${1:-}" = capture ] || { echo "unsupported gbrain call: $*" >&2; exit 2; }
shift
slug=""; file=""
while [ $# -gt 0 ]; do
  case $1 in
    --slug) slug=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    --type|--source) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${FM_TEST_PAGES:-}" ] || { echo "the fake brain needs FM_TEST_PAGES" >&2; exit 3; }
[ -n "${GBRAIN_HOME:-}" ] || { echo "a capture must name the home's own brain" >&2; exit 4; }
mkdir -p "$FM_TEST_PAGES"
cp "$file" "$FM_TEST_PAGES/$(printf '%s' "$slug" | tr '/' '_').md"
# GBrain 0.42.69.0 prefixes its JSON receipt with any import warnings, so the
# stub reproduces that shape rather than a clean document.
printf '[import] NOTE: reindexing %s\n' "$slug"
printf '{\n  "slug": "%s",\n  "status": "created_or_updated",\n  "chunks": 1\n}\n' "$slug"
SH
      ;;
  esac
  chmod +x "$home/fakebin/gbrain" 2>/dev/null || true
}

cap() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_PAGES="$home/pages" \
    FM_GBRAIN_BIN="$home/fakebin/gbrain" \
    PATH="$home/fakebin:$PATH" "$CAPTURE" "$@"
}

seed_manifest() {  # <home> <id> <title>
  local home=$1 id=$2 title=$3
  mkdir -p "$home/data/$id"
  jq -n --arg id "$id" --arg t "$title" '{
    schema: "fm-outcome-manifest.v1", task_id: $id, title: $t,
    project: "/projects/widget", kind: "ship", mode: "no-mistakes",
    outcome: {state: "done", detail: "landed"},
    timestamps: {completed: "2026-08-04T10:00:00Z"},
    pr: {url: "https://github.com/acme/widget/pull/9"},
    work_items: {references: [{url: "https://github.com/acme/widget/issues/3"}]}
  }' > "$home/data/$id/outcome.json"
}

seed_report() {  # <home> <id>  < body
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/report.md"
}

doc_id_for() {  # <home> <id>
  cap "$1" status --json | jq -r --arg id "$2" '.documents[] | select(.source.id == $id) | .document_id'
}

item_field() {  # <home> <task-id> <jq-path>
  local doc
  doc=$(doc_id_for "$1" "$2")
  cap "$1" show "$doc" | jq -r "$3"
}

pages_count() { find "$1/pages" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

# The reported cause of a silent listing failure: the listing builds its slugs in
# a printf | awk | sort pipeline that runs under pipefail, so a member that dies
# without a message returns non-zero with nothing on stderr. awk is reached
# nowhere else on the audit path, so shadowing it on the fake bin's PATH
# reproduces exactly that failure and nothing else.
mute_awk() {  # <home>
  printf '#!/usr/bin/env bash\nexit 3\n' > "$1/fakebin/awk"
  chmod +x "$1/fakebin/awk"
}

# --- inert without a brain --------------------------------------------------

test_capture_is_inert_without_a_brain() {
  local home
  home=$(make_home inert --no-brain)
  seed_manifest "$home" ship-a "Add the widget"
  cap "$home" task ship-a || fail "capture must exit 0 in a home with no brain"
  [ ! -e "$home/state/ship-a.gbrain" ] || fail "a home with no brain must leave no capture receipt"
  [ ! -d "$home/data/gbrain-outbox" ] || fail "a home with no brain must create no outbox"
  cap "$home" task ship-a --require-brain >/dev/null 2>&1 \
    && fail "--require-brain must report the missing brain"
  pass "capture is inert until a home has a brain"
}

# --- redaction --------------------------------------------------------------

# Assembled from fragments so this fixture cannot itself trip a secret scanner
# and block a push: GitHub push protection rejected an earlier revision of this
# file over the literal form. The redactor still receives a complete xoxb- token
# at runtime, which is the whole point of the case, so do not "tidy" this back
# into a literal. The GitHub and AWS fixtures below stay literal deliberately -
# GitHub checksums its own tokens and AKIAIOSFODNN7EXAMPLE is AWS's documented
# example key, so neither is scanner-matching.
slack_token_fixture() { printf 'xox%s-1234567890-abcdefghijklmn' b; }

secret_report() {
  sed "s|__SLACK_TOKEN__|$(slack_token_fixture)|" <<'EOF'
# Findings

CI passed GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz012345 to the job.
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIabcdEXAMPLEKEY and AKIAIOSFODNN7EXAMPLE were in the env.
curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl' https://api.example.com
The registry was https://deploy:hunter2secret@registry.example.com/v2/
The relay used __SLACK_TOKEN__ and the brain client secret gbrain_cs_lZq8xTOPSECRETvalue.
We reran it with --token s3cr3tvalue123 and api_key: AbCdEf123456.
The retry used --token aGVsbG8gd29ybGQxMjM0NTY= against staging.
The console needed --password Sk1pZr4g:ment9asswordXY here.
The publish step took --api-key Ke7PreF1x=EightValue22 as well.
The regression is an off-by-one in the cache key.
EOF
}

test_representative_secrets_are_redacted_before_they_reach_disk() {
  local home outbox page secret
  home=$(make_home redaction)
  seed_manifest "$home" ship-a "Add the widget"
  secret_report | seed_report "$home" ship-a
  cap "$home" task ship-a --require-brain >/dev/null || fail "capture must succeed"

  outbox="$home/data/gbrain-outbox/$(doc_id_for "$home" ship-a).json"
  [ -f "$outbox" ] || fail "the outbox record must exist"
  page=$(find "$home/pages" -name '*.md' | head -1)
  [ -n "$page" ] || fail "the document must have been delivered"

  # Asserted against the OUTBOX as well as the page: redaction that only ran on
  # the way out would still have written the secret to disk.
  #
  # The last three are whitespace-separated arguments whose VALUE carries a "="
  # or a ":". A cut point taken from the first separator character anywhere in
  # the match, rather than from the separator the matched pattern uses, keeps
  # everything up to it verbatim: the leading fragment of each of these leaks,
  # and the base64 value whose only "=" is its padding survives whole. Only the
  # leading fragment is asserted for the last two, because that is the part such
  # a cut point keeps.
  for secret in ghp_abcdefghijklmnopqrstuvwxyz012345 wJalrXUtnFEMIabcdEXAMPLEKEY \
                AKIAIOSFODNN7EXAMPLE eyJhbGciOiJIUzI1NiJ9 hunter2secret \
                "$(slack_token_fixture)" gbrain_cs_lZq8xTOPSECRETvalue \
                s3cr3tvalue123 AbCdEf123456 \
                aGVsbG8gd29ybGQxMjM0NTY= Sk1pZr4g Ke7PreF1x; do
    grep -qF "$secret" "$outbox" && fail "the outbox stored the secret $secret"
    grep -qF "$secret" "$page" && fail "the delivered page carried the secret $secret"
  done
  grep -q 'off-by-one in the cache key' "$page" || fail "redaction must keep the actual finding"
  cap "$home" status | grep -q 'redacted   [1-9]' || fail "status must report what was redacted"
  pass "representative tokens, credentials, environment values and tool arguments never reach disk"
}

test_an_unterminated_private_key_is_refused_rather_than_stored() {
  local home
  home=$(make_home unterminated)
  seed_manifest "$home" ship-a "Add the widget"
  printf '# Key\n\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxyzTRUNCATED\n' \
    | seed_report "$home" ship-a
  cap "$home" task ship-a >/dev/null 2>&1 || fail "a refusal must not fail the caller"
  [ ! -d "$home/data/gbrain-outbox" ] || [ -z "$(find "$home/data/gbrain-outbox" -name '*.json')" ] \
    || fail "a refused body must never be written to the outbox"
  [ "$(pages_count "$home")" = 0 ] || fail "a refused body must never be delivered"
  grep -q '^status=skipped' "$home/state/ship-a.gbrain" \
    || fail "a refusal must be recorded as skipped"
  grep -q 'survived redaction' "$home/state/ship-a.gbrain" \
    || fail "the receipt must say why it was refused"
  pass "an unterminated private key is rejected outright, not partially rewritten"
}

test_a_terminated_private_key_block_is_replaced() {
  local home page
  home=$(make_home keyblock)
  seed_manifest "$home" ship-a "Add the widget"
  printf '# Key\n\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n\nthe fix was a retry\n' \
    | seed_report "$home" ship-a
  cap "$home" task ship-a --require-brain >/dev/null || fail "capture must succeed"
  page=$(find "$home/pages" -name '*.md' | head -1)
  grep -q 'b3BlbnNzaC1rZXktdjEAAAAA' "$page" && fail "key material must not survive"
  grep -q 'redacted:private-key' "$page" || fail "the block must leave a marker"
  grep -q 'the fix was a retry' "$page" || fail "content after the block must survive"
  pass "a complete private-key block is replaced whole and the rest of the document survives"
}

test_a_title_carrying_a_backslash_stays_valid_frontmatter() {
  local home page front
  home=$(make_home yamlescape)
  # A backslash inside a double-quoted YAML scalar starts an escape, and one at
  # the very end escapes the closing quote and swallows the lines after it.
  seed_manifest "$home" ship-a "fix C:\\Users path and a trailer\\"
  printf '# Findings\n\nthe path separator was wrong\n' | seed_report "$home" ship-a
  cap "$home" task ship-a --require-brain >/dev/null || fail "capture must succeed"
  page=$(find "$home/pages" -name '*.md' | head -1)
  [ -n "$page" ] || fail "the document must have been delivered"
  front=$(awk 'NR > 1 && /^---$/ {exit} NR > 1 {print}' "$page")
  printf '%s\n' "$front" | grep -qF 'title: "fix C:\\Users path and a trailer\\"' \
    || fail "a backslash in a title must be escaped: $front"
  printf '%s\n' "$front" | grep -q '^firstmate_task_id: ship-a$' \
    || fail "the frontmatter after the title must survive: $front"
  pass "a title carrying a backslash produces valid frontmatter"
}

test_an_out_of_shape_document_id_is_refused_before_it_becomes_a_path() {
  local home
  home=$(make_home docid)
  seed_manifest "$home" ship-a "Add the widget"
  cap "$home" task ship-a --require-brain >/dev/null || fail "capture must succeed"
  # The id becomes $DATA/gbrain-outbox/<id>.json, so a traversal must be refused
  # rather than read - and written back to - outside the outbox.
  cap "$home" show '../../x' >/dev/null 2>&1 && fail "show must refuse a traversal id"
  cap "$home" show 'v1/etc/passwd' >/dev/null 2>&1 && fail "show must refuse a path-shaped id"
  cap "$home" process --document '../../x' >/dev/null 2>&1 \
    && fail "process must refuse a traversal id"
  cap "$home" show "$(doc_id_for "$home" ship-a)" >/dev/null \
    || fail "a well-shaped document id must still be readable"
  pass "an out-of-shape document id is refused before it reaches a path"
}

test_capture_never_reads_a_brief_or_a_credential_store() {
  local home outbox
  home=$(make_home sources)
  seed_manifest "$home" ship-a "Add the widget"
  printf '# Findings\n\nthe retry budget was too low\n' | seed_report "$home" ship-a
  # Records the composer must never open, each carrying a distinctive marker.
  printf 'brief secret ghp_briefTOKENvalue0123456789\n' > "$home/data/ship-a/brief.md"
  mkdir -p "$home/config/gbrain-secrets"
  printf 'gbrain_cs_credentialSTOREvalue\n' > "$home/config/gbrain-secrets/main"
  chmod 600 "$home/config/gbrain-secrets/main"
  printf 'FM_TEST_ENV=envSTOREvalue0123\n' > "$home/config/x-mode.env"
  cap "$home" task ship-a --require-brain >/dev/null || fail "capture must succeed"
  outbox="$home/data/gbrain-outbox/$(doc_id_for "$home" ship-a).json"
  grep -q 'briefTOKENvalue' "$outbox" && fail "the composer read the brief"
  grep -q 'credentialSTOREvalue' "$outbox" && fail "the composer read a credential store"
  grep -q 'envSTOREvalue' "$outbox" && fail "the composer read an environment file"
  grep -q 'retry budget was too low' "$outbox" || fail "the report must be captured"
  pass "the composer's inputs are enumerated: no brief, no credential store, no environment file"
}

# --- identity and idempotency ----------------------------------------------

test_identity_is_deterministic_and_delivery_is_idempotent() {
  local home first second doc_id rev1 rev2
  home=$(make_home identity)
  seed_manifest "$home" ship-a "Add the widget"
  printf '# Findings\n\nthe cache key was wrong\n' | seed_report "$home" ship-a
  cap "$home" task ship-a --require-brain >/dev/null || fail "first capture must succeed"
  doc_id=$(doc_id_for "$home" ship-a)
  first=$(item_field "$home" ship-a '.content_version')
  rev1=$(item_field "$home" ship-a '.revision_id')

  cap "$home" task ship-a --require-brain >/dev/null || fail "second capture must succeed"
  [ "$(pages_count "$home")" = 1 ] || fail "recapture must not create a second page"
  [ "$(doc_id_for "$home" ship-a)" = "$doc_id" ] || fail "the document id must be stable"
  [ "$(item_field "$home" ship-a '.content_version')" = "$first" ] \
    || fail "unchanged content must keep its content version"

  cap "$home" process --force >/dev/null || fail "a forced re-delivery must succeed"
  [ "$(pages_count "$home")" = 1 ] || fail "replaying an outbox item must stay one page"

  # A changed body is a new REVISION of the same logical document, so it still
  # updates one page rather than adding another.
  printf '# Findings\n\nthe cache key was wrong, and so was its expiry\n' | seed_report "$home" ship-a
  cap "$home" task ship-a --require-brain >/dev/null || fail "recapture must succeed"
  second=$(item_field "$home" ship-a '.content_version')
  rev2=$(item_field "$home" ship-a '.revision_id')
  [ "$first" != "$second" ] || fail "changed content must change the content version"
  [ "$rev1" != "$rev2" ] || fail "changed content must change the revision id"
  [ "$(doc_id_for "$home" ship-a)" = "$doc_id" ] || fail "a new revision is not a new document"
  [ "$(pages_count "$home")" = 1 ] || fail "a new revision must update the one page"
  grep -q 'and so was its expiry' "$(find "$home/pages" -name '*.md' | head -1)" \
    || fail "the page must carry the new revision"
  pass "identity is deterministic, and repeated delivery updates one logical document"
}

test_two_homes_never_share_a_document() {
  local a b
  a=$(make_home twohomes-a)
  b=$(make_home twohomes-b)
  seed_manifest "$a" ship-a "Add the widget"
  seed_manifest "$b" ship-a "Add the widget"
  cap "$a" task ship-a --require-brain >/dev/null || fail "capture in home a must succeed"
  cap "$b" task ship-a --require-brain >/dev/null || fail "capture in home b must succeed"
  [ "$(item_field "$a" ship-a '.slug')" != "$(item_field "$b" ship-a '.slug')" ] \
    || fail "two homes capturing the same task id must not share one page address"
  pass "the same task id in two homes resolves to two documents"
}

# --- durability under failure ----------------------------------------------

test_a_stopped_brain_leaves_a_durable_pending_item() {
  local home
  home=$(make_home stopped)
  seed_manifest "$home" ship-a "Add the widget"
  printf '# Findings\n\nthe queue drained twice\n' | seed_report "$home" ship-a
  fake_gbrain "$home" missing
  cap "$home" task ship-a >/dev/null 2>&1 || fail "a stopped brain must not fail the caller"
  [ "$(item_field "$home" ship-a '.status')" = pending ] \
    || fail "a stopped brain must leave the item pending"
  grep -q 'the queue drained twice' "$home/data/gbrain-outbox/$(doc_id_for "$home" ship-a).json" \
    || fail "the pending item must carry the knowledge, not just a marker"
  grep -q '^status=pending' "$home/state/ship-a.gbrain" || fail "the receipt must say pending"
  grep -q '^receipt=firstmate/' "$home/state/ship-a.gbrain" \
    || fail "a pending receipt must still name the page address"

  fake_gbrain "$home" ok
  cap "$home" process >/dev/null || fail "the retry must capture the pending item"
  [ "$(item_field "$home" ship-a '.status')" = captured ] || fail "the retry must mark it captured"
  grep -q 'the queue drained twice' "$(find "$home/pages" -name '*.md' | head -1)" \
    || fail "the retried delivery must carry the original knowledge"
  pass "stopping the brain leaves a durable pending item that a later retry captures"
}

test_delivery_is_bounded_and_leaves_the_item_pending() {
  local home started elapsed
  home=$(make_home bounded)
  seed_manifest "$home" ship-a "Add the widget"
  fake_gbrain "$home" hang
  started=$(date +%s)
  cap "$home" task ship-a --timeout 2 >/dev/null 2>&1 || fail "a hung brain must not fail the caller"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 20 ] || fail "a hung brain blocked the caller for ${elapsed}s"
  [ "$(item_field "$home" ship-a '.status')" = pending ] || fail "a hung delivery must stay pending"
  item_field "$home" ship-a '.last_error' | grep -q 'did not finish' \
    || fail "the item must record why delivery stopped"
  pass "a hung brain is cut off by the timeout and leaves a pending item"
}

test_retry_is_bounded_and_force_resumes_it() {
  local home attempt
  home=$(make_home retrybound)
  seed_manifest "$home" ship-a "Add the widget"
  fake_gbrain "$home" fail
  FM_GBRAIN_CAPTURE_MAX_ATTEMPTS=2 cap "$home" task ship-a >/dev/null 2>&1 || true
  for attempt in 1 2 3; do
    printf '%s' "$attempt" >/dev/null
    FM_GBRAIN_CAPTURE_MAX_ATTEMPTS=2 cap "$home" process >/dev/null 2>&1 || true
  done
  [ "$(item_field "$home" ship-a '.status')" = failed ] \
    || fail "an item must stop being retried once its attempts are exhausted"
  [ "$(item_field "$home" ship-a '.attempts')" -le 3 ] \
    || fail "an exhausted item must not keep consuming attempts"
  item_field "$home" ship-a '.last_error' | grep -q 'index is locked' \
    || fail "the item must record the brain's own reason"

  fake_gbrain "$home" ok
  cap "$home" process >/dev/null 2>&1 && fail "an exhausted item must not be retried without --force"
  cap "$home" process --force >/dev/null || fail "--force must retry an exhausted item"
  [ "$(item_field "$home" ship-a '.status')" = captured ] || fail "the forced retry must capture it"
  pass "retry is bounded, and --force resumes an exhausted item"
}

test_a_partially_written_record_is_reported_not_believed() {
  local home doc outbox
  home=$(make_home partial)
  seed_manifest "$home" ship-a "Add the widget"
  fake_gbrain "$home" missing
  cap "$home" task ship-a >/dev/null 2>&1 || true
  doc=$(doc_id_for "$home" ship-a)
  outbox="$home/data/gbrain-outbox/$doc.json"
  # Exactly what a crash mid-write would leave if the write were not atomic.
  head -c 60 "$outbox" > "$outbox.part" && mv "$outbox.part" "$outbox"
  fake_gbrain "$home" ok
  cap "$home" status | grep -q 'unreadable 1' || fail "status must disclose an unreadable record"
  cap "$home" process >/dev/null 2>&1 && fail "process must not report an unreadable record as done"
  cap "$home" process 2>&1 | grep -q "$doc unreadable" || fail "process must name the bad record"
  cap "$home" show "$doc" >/dev/null 2>&1 && fail "show must refuse a malformed record"
  [ "$(pages_count "$home")" = 0 ] || fail "a malformed record must never be delivered"

  # The task itself is not lost: recomposing from the durable records repairs it.
  cap "$home" task ship-a --require-brain >/dev/null || fail "recapture must repair the record"
  [ "$(item_field "$home" ship-a '.status')" = captured ] || fail "the repaired item must capture"
  pass "a partially written record is reported and repairable, never silently believed"
}

# --- backfill ---------------------------------------------------------------

test_backfill_is_restartable_and_reports_counts() {
  local home out
  home=$(make_home backfill)
  seed_manifest "$home" ship-a "Add the widget"
  seed_manifest "$home" ship-b "Fix the drain"
  printf '# Report\n\nthe drain retried twice\n' | seed_report "$home" scout-c
  mkdir -p "$home/data/no-artifacts"

  fake_gbrain "$home" fail
  out=$(cap "$home" backfill 2>&1) || true
  printf '%s' "$out" | grep -q 'scanned=3' || fail "backfill must scan every task with a durable record: $out"
  printf '%s' "$out" | grep -q 'enqueued=3' || fail "backfill must enqueue what it scanned: $out"
  printf '%s' "$out" | grep -q 'errors=3' || fail "backfill must report delivery errors: $out"

  # Restart: the durable records survive, so the rerun simply delivers them.
  fake_gbrain "$home" ok
  out=$(cap "$home" backfill 2>&1) || fail "the restarted backfill must succeed: $out"
  printf '%s' "$out" | grep -q 'captured=3' || fail "the restart must capture what was pending: $out"
  [ "$(pages_count "$home")" = 3 ] || fail "backfill must deliver one page per task"

  # A second complete run re-delivers nothing.
  out=$(cap "$home" backfill 2>&1) || fail "a repeat backfill must succeed: $out"
  printf '%s' "$out" | grep -q 'already-captured=3' || fail "a repeat backfill must be a no-op: $out"
  [ "$(pages_count "$home")" = 3 ] || fail "a repeat backfill must not duplicate pages"

  cap "$home" backfill --dry-run 2>&1 | grep -q 'would capture ship-a' \
    || fail "--dry-run must report without writing"
  pass "backfill is restartable, bounded, and reports counts and errors"
}

test_backfill_records_a_refusal_without_stopping() {
  local home out
  home=$(make_home backfill-refuse)
  seed_manifest "$home" ship-a "Add the widget"
  seed_manifest "$home" ship-bad "Bad report"
  printf '# Key\n\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAtruncated\n' \
    | seed_report "$home" ship-bad
  out=$(cap "$home" backfill 2>&1) || true
  printf '%s' "$out" | grep -q 'refused=1' || fail "backfill must count a refusal: $out"
  printf '%s' "$out" | grep -q 'captured=1' || fail "a refusal must not stop the sweep: $out"
  grep -q '^status=skipped' "$home/state/ship-bad.gbrain" || fail "the refusal must leave a receipt"
  pass "backfill records a refused document and keeps going"
}

# --- /stow surface ----------------------------------------------------------

test_status_reports_archived_pending_skipped_and_redacted() {
  local home json
  home=$(make_home stow)
  seed_manifest "$home" ship-a "Add the widget"
  secret_report | seed_report "$home" ship-a
  cap "$home" task ship-a --require-brain >/dev/null || fail "capture must succeed"
  seed_manifest "$home" ship-bad "Bad report"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEtruncated\n' | seed_report "$home" ship-bad
  cap "$home" task ship-bad >/dev/null 2>&1 || true
  seed_manifest "$home" ship-c "Pending one"
  fake_gbrain "$home" missing
  cap "$home" task ship-c >/dev/null 2>&1 || true

  json=$(cap "$home" status --json)
  [ "$(printf '%s' "$json" | jq -r '.totals.archived')" = 1 ] || fail "status must count archived"
  [ "$(printf '%s' "$json" | jq -r '.totals.pending')" = 1 ] || fail "status must count pending"
  [ "$(printf '%s' "$json" | jq -r '.totals.redacted_values')" -gt 0 ] \
    || fail "status must count redacted values"
  # A refused document never becomes an outbox record, so its skipped state is
  # in the receipt the manifest reads rather than in the outbox listing.
  grep -q '^status=skipped' "$home/state/ship-bad.gbrain" || fail "a refusal must be visible"
  printf '%s' "$json" | jq -e '.documents[] | select(.body)' >/dev/null 2>&1 \
    && fail "status must not project document bodies"
  pass "status reports what was archived, left pending, and redacted"
}

test_a_note_goes_through_the_same_path() {
  local home
  home=$(make_home notes)
  printf 'The reranker fails over 4096 tokens and returns the non-reranked order.\n' \
    > "$TMP_ROOT/note.md"
  cap "$home" note --id fleet-reranker --title "Reranker context bound" --file "$TMP_ROOT/note.md" \
    >/dev/null || fail "a note must capture"
  grep -q 'non-reranked order' "$(find "$home/pages" -name '*note*' | head -1)" \
    || fail "the note body must be delivered"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEtruncated\n' > "$TMP_ROOT/bad-note.md"
  cap "$home" note --id fleet-bad --title "Bad" --file "$TMP_ROOT/bad-note.md" >/dev/null 2>&1 \
    && fail "a note carrying an unterminated key must be refused"

  # A routing step that offers to store a note must be a no-op, not an error,
  # in a home that has no brain.
  local bare
  bare=$(make_home notes-nobrain --no-brain)
  cap "$bare" note --id fleet-x --title "X" --file "$TMP_ROOT/note.md" >/dev/null 2>&1 \
    || fail "a note in a home with no brain must be inert, not an error"
  [ ! -d "$bare/data/gbrain-outbox" ] || fail "an inert note must store nothing"
  pass "a routed note uses the same redaction and refusal path as a task"
}

# --- teardown integration ---------------------------------------------------

# A minimal task whose work has landed on the local default branch, which is the
# smallest shape bin/fm-teardown.sh will actually clean up.
make_teardown_case() {  # <name> [--no-brain]
  local name=$1 case_dir
  case_dir=$(make_home "$name" "${2:-}")
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/tmux" "$case_dir/fakebin/gh-axi"

  git init -q "$case_dir/project"
  git -C "$case_dir/project" symbolic-ref HEAD refs/heads/main
  git -C "$case_dir/project" commit -q --allow-empty -m baseline
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf 'fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add -- fix.txt
  git -C "$case_dir/wt" commit -q -m "the fix"
  git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "model=default"
  printf 'done: the fix landed\n' > "$case_dir/state/task-x1.status"
  mkdir -p "$case_dir/data/task-x1"
  printf '# brief\n' > "$case_dir/data/task-x1/brief.md"
  printf '%s\n' "$case_dir"
}

run_teardown() {  # <case-dir>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEST_PAGES="$case_dir/pages" \
  FM_GBRAIN_BIN="$case_dir/fakebin/gbrain" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_teardown_captures_and_the_manifest_carries_the_receipt() {
  local case_dir manifest slug page
  case_dir=$(make_teardown_case teardown-capture)
  printf '# Findings\n\nthe drain retried twice before the fix\n' \
    > "$case_dir/data/task-x1/report.md"
  run_teardown "$case_dir" >/dev/null 2>&1 || fail "teardown must succeed"

  # The point of the whole story: the volatile records are gone and the task is
  # still retrievable from what survived.
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "teardown must remove the volatile metadata"
  [ ! -e "$case_dir/state/task-x1.gbrain" ] || fail "teardown must remove the volatile receipt"
  manifest="$case_dir/data/task-x1/outcome.json"
  [ -f "$manifest" ] || fail "the durable manifest must exist"
  [ "$(jq -r '.gbrain.status' "$manifest")" = captured ] \
    || fail "the manifest must record that the task was captured"
  slug=$(jq -r '.gbrain.receipt' "$manifest")
  [ -n "$slug" ] && [ "$slug" != null ] || fail "the manifest must carry the page reference"
  page="$case_dir/pages/$(printf '%s' "$slug" | tr '/' '_').md"
  [ -f "$page" ] || fail "the manifest's page reference must resolve to the captured document"
  grep -q 'the drain retried twice' "$page" \
    || fail "the retrieved document must carry the task's knowledge"
  grep -q "firstmate_task_id: task-x1" "$page" \
    || fail "the retrieved document must identify its task"
  pass "a completed task is retrievable from the durable manifest after its volatile records are gone"
}

# The manifest is written twice so the capture receipt can reach it. Both writes
# must record ONE completion: if the republish re-derived it, the manifest left
# on disk would disagree with the body already delivered, and the next backfill
# would read that as changed content and re-deliver every captured task once.
test_teardown_leaves_the_manifest_agreeing_with_the_captured_body() {
  local case_dir manifest completed page out
  case_dir=$(make_teardown_case teardown-completed)
  printf '# Findings\n\nthe drain retried twice before the fix\n' \
    > "$case_dir/data/task-x1/report.md"
  # A capture window wide enough that a re-derived timestamp must differ.
  fake_gbrain "$case_dir" slow
  run_teardown "$case_dir" >/dev/null 2>&1 || fail "teardown must succeed"

  manifest="$case_dir/data/task-x1/outcome.json"
  completed=$(jq -r '.timestamps.completed' "$manifest")
  [ -n "$completed" ] && [ "$completed" != null ] || fail "the manifest must record a completion"
  [ "$(jq -r '.recorded_at' "$manifest")" = "$completed" ] \
    || fail "recorded_at must still equal the recorded completion"
  page="$case_dir/pages/$(jq -r '.gbrain.receipt' "$manifest" | tr '/' '_').md"
  [ -f "$page" ] || fail "the manifest's page reference must resolve"
  grep -qF "firstmate_completed: $completed" "$page" \
    || fail "the delivered body and the manifest must agree on the completion time"

  fake_gbrain "$case_dir" ok
  out=$(cap "$case_dir" backfill 2>&1) || fail "the backfill must succeed: $out"
  printf '%s' "$out" | grep -q 'already-captured=1' \
    || fail "a backfill after teardown must re-deliver nothing: $out"
  [ "$(pages_count "$case_dir")" = 1 ] || fail "a backfill after teardown must not add a page"
  pass "teardown leaves the manifest and the captured body agreeing on the completion time"
}

test_teardown_is_never_blocked_by_the_brain() {
  local case_dir started elapsed
  case_dir=$(make_teardown_case teardown-hang)
  fake_gbrain "$case_dir" hang
  started=$(date +%s)
  FM_GBRAIN_CAPTURE_TIMEOUT=2 run_teardown "$case_dir" >/dev/null 2>&1 \
    || fail "a hung brain must not fail teardown"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 60 ] || fail "a hung brain delayed teardown by ${elapsed}s"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "teardown must still complete"
  [ -f "$case_dir/data/task-x1/outcome.json" ] || fail "the manifest must still be published"
  # Nothing was lost: the durable item is still there for a later retry.
  [ -n "$(find "$case_dir/data/gbrain-outbox" -name '*.json' 2>/dev/null)" ] \
    || fail "a hung delivery must still leave a durable outbox item"
  fake_gbrain "$case_dir" ok
  cap "$case_dir" process >/dev/null || fail "the item must capture after teardown"
  [ "$(pages_count "$case_dir")" = 1 ] || fail "the post-teardown retry must deliver the document"
  pass "a hung brain neither blocks teardown nor loses the task's knowledge"
}

test_teardown_in_a_home_without_a_brain_is_unchanged() {
  local case_dir
  case_dir=$(make_teardown_case teardown-nobrain --no-brain)
  run_teardown "$case_dir" >/dev/null 2>&1 || fail "teardown must succeed with no brain"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "teardown must complete"
  [ "$(jq -r '.gbrain.status' "$case_dir/data/task-x1/outcome.json")" = absent \
    ] || fail "a home with no brain must record no capture provider"
  [ ! -d "$case_dir/data/gbrain-outbox" ] || fail "a home with no brain must create no outbox"
  pass "teardown in a home without a brain behaves exactly as before"
}

# --- the cut body says so ---------------------------------------------------

test_a_truncated_body_is_marked_rather_than_left_looking_complete() {
  local home page
  home=$(make_home truncation)
  seed_manifest "$home" scout-big "Investigate the drain"
  # Comfortably past the cap, with a distinctive tail that must NOT survive: a
  # marker on a body that was never actually cut would prove nothing.
  {
    printf '# Report\n\n'
    awk 'BEGIN { while (i++ < 3000) print "the drain retried twice and the cache key was off by one" }'
    printf '\nTHE-TAIL-THAT-IS-LOST\n'
  } | seed_report "$home" scout-big
  cap "$home" task scout-big --require-brain >/dev/null || fail "capture must succeed"

  page=$(find "$home/pages" -name '*.md' | head -1)
  [ -n "$page" ] || fail "the document must have been delivered"
  grep -q 'THE-TAIL-THAT-IS-LOST' "$page" && fail "the body must actually have been cut"
  grep -q 'Capture truncated at' "$page" \
    || fail "a cut page must carry a marker its reader can see"
  [ "$(item_field "$home" scout-big '.truncated')" = true ] \
    || fail "a cut record must say so without anyone parsing its prose"
  [ "$(item_field "$home" scout-big '.captured_bytes')" -gt 0 ] \
    || fail "a cut record must name how much it kept"
  cap "$home" status --json | jq -e '.totals.truncated == 1' >/dev/null \
    || fail "status must count cut bodies"

  # The counterpart: a body that fits is not marked, so the marker means
  # something rather than appearing on every page.
  seed_manifest "$home" ship-small "Add the widget"
  printf '# Report\n\nshort and complete\n' | seed_report "$home" ship-small
  cap "$home" task ship-small --require-brain >/dev/null || fail "the small capture must succeed"
  [ "$(item_field "$home" ship-small '.truncated')" = false ] \
    || fail "a body that fits must not be marked truncated"
  cap "$home" show "$(doc_id_for "$home" ship-small)" | jq -r '.body' | grep -q 'Capture truncated' \
    && fail "a body that fits must carry no marker"
  pass "a body cut at the cap is marked on the page and on the record"
}

# --- captured is not the same as served -------------------------------------

test_the_audit_names_a_captured_document_the_index_no_longer_serves() {
  local home out
  home=$(make_home audit)
  seed_manifest "$home" ship-a "Add the widget"
  seed_manifest "$home" ship-b "Fix the drain"
  cap "$home" backfill >/dev/null 2>&1 || fail "backfill must deliver both tasks"
  out=$(cap "$home" audit 2>&1) || fail "an audit with both pages served must pass: $out"
  printf '%s' "$out" | grep -q 'state      ok' || fail "a matching audit must read ok: $out"

  # Exactly what a soft-delete looks like from outside: the record still says
  # captured, and the page is gone from the listing.
  rm -f "$home/pages/firstmate_"*"_task_ship-b.md"
  out=$(cap "$home" audit 2>&1) && fail "an audit that found a gap must exit non-zero"
  printf '%s' "$out" | grep -q 'state      gap' || fail "the audit must report the gap: $out"
  printf '%s' "$out" | grep -q 'task/ship-b' || fail "the audit must name the missing document: $out"
  printf '%s' "$out" | grep -q 'missing    1' || fail "the audit must count the gap: $out"

  # The durable record is what the dashboard and the session start replay, so it
  # has to carry the same verdict rather than being re-derived by each of them.
  jq -e '.schema == "fm-gbrain-capture-audit.v1" and .state == "gap" and .missing == 1' \
    "$home/state/.gbrain-audit" >/dev/null \
    || fail "the audit must leave its verdict on disk"
  pass "the audit names a captured document the index no longer serves"
}

test_an_index_listing_that_could_not_be_read_is_not_reported_as_a_gap() {
  local home out
  home=$(make_home audit-inconclusive)
  seed_manifest "$home" ship-a "Add the widget"
  cap "$home" backfill >/dev/null 2>&1 || fail "backfill must deliver the task"

  # A false gap is what would train an operator to ignore a real one, so a
  # listing that answered nothing must never be read as "every page is gone".
  fake_gbrain "$home" fail
  out=$(cap "$home" audit 2>&1) && fail "an audit that compared nothing must exit non-zero"
  printf '%s' "$out" | grep -q 'state      inconclusive' \
    || fail "an unreadable listing must be inconclusive: $out"
  printf '%s' "$out" | grep -q 'missing    not measured' \
    || fail "an unreadable listing must claim nothing about missing documents: $out"
  printf '%s' "$out" | grep -q 'missing    0' \
    && fail "an unreadable listing must not report a count nobody measured: $out"

  # The same rule for a listing that came back exactly at its own ceiling.
  fake_gbrain "$home" ok
  out=$(FM_GBRAIN_CAPTURE_AUDIT_MAX_PAGES=1 cap "$home" audit 2>&1) \
    && fail "a listing at its ceiling must exit non-zero"
  printf '%s' "$out" | grep -q 'state      inconclusive' \
    || fail "a listing at its own ceiling must be inconclusive: $out"
  pass "a listing that proved nothing is inconclusive rather than a gap"
}

# The fail-closed rule has to be decided from whether the listing WORKED, never
# from whether it explained itself. A listing that dies without a message once
# emptied the active set while leaving the failure invisible, which turned every
# captured document into a reported gap - the largest false gap the design can
# produce, on the exact branch that exists to prevent one.
test_a_listing_that_fails_without_a_message_is_still_inconclusive() {
  local home out record
  home=$(make_home audit-mute)
  seed_manifest "$home" ship-a "Add the widget"
  seed_manifest "$home" ship-b "Fix the drain"
  cap "$home" backfill >/dev/null 2>&1 || fail "backfill must deliver both tasks"

  mute_awk "$home"
  out=$(cap "$home" audit 2>&1) \
    && fail "an audit that compared nothing must exit non-zero"
  printf '%s' "$out" | grep -q 'state      inconclusive' \
    || fail "a listing that failed silently must be inconclusive: $out"
  printf '%s' "$out" | grep -q 'state      gap' \
    && fail "a listing that answered nothing must never name a gap: $out"
  printf '%s' "$out" | grep -q 'ship-a' \
    && fail "a listing that answered nothing must name no missing document: $out"

  # Nothing was compared, so nothing is counted: a zero here would be a claim
  # nobody measured, and the durable record is what every surface replays.
  record=$home/state/.gbrain-audit
  jq -e '.state == "inconclusive" and .active == null and .missing == null
         and (.missing_slugs | length) == 0
         and .bounds.active == "unmeasured" and .bounds.missing == "unmeasured"
         and .stored == 2 and .bounds.stored == "exact"' "$record" >/dev/null \
    || fail "an unmeasured side must be recorded as unmeasured: $(cat "$record")"
  printf '%s' "$out" | grep -q 'active     not measured' \
    || fail "the human output must say the active side was not measured: $out"
  printf '%s' "$out" | grep -q 'missing    not measured' \
    || fail "the human output must say nothing was compared: $out"
  printf '%s' "$out" | grep -q 'without saying why' \
    || fail "a failure with no message must still name itself: $out"
  pass "a listing that failed without a message is inconclusive, not a gap"
}

# The opposite dishonesty: a capped listing DID measure, so discarding what it
# found would be as wrong as inventing what it did not. Its counts are kept and
# marked with the direction each one can be wrong in.
test_a_capped_listing_keeps_its_counts_as_bounds() {
  local home out record
  home=$(make_home audit-capped)
  seed_manifest "$home" ship-a "Add the widget"
  seed_manifest "$home" ship-b "Fix the drain"
  cap "$home" backfill >/dev/null 2>&1 || fail "backfill must deliver both tasks"
  rm -f "$home/pages/firstmate_"*"_task_ship-b.md"

  out=$(FM_GBRAIN_CAPTURE_AUDIT_MAX_PAGES=1 cap "$home" audit 2>&1) \
    && fail "a listing at its ceiling must exit non-zero"
  record=$home/state/.gbrain-audit
  jq -e '.state == "inconclusive" and .active == 1 and .missing == 1
         and .bounds.active == "at-least" and .bounds.missing == "at-most"
         and (.missing_slugs | length) == 1' "$record" >/dev/null \
    || fail "a partial listing must keep the counts it measured: $(cat "$record")"
  printf '%s' "$out" | grep -q 'active     at least 1' \
    || fail "a partial active count must read as a floor: $out"
  printf '%s' "$out" | grep -q 'missing    at most 1' \
    || fail "a partial missing count must read as a ceiling: $out"
  printf '%s' "$out" | grep -q '  candidate .*task/ship-b' \
    || fail "a partial listing must name its documents as candidates: $out"
  printf '%s' "$out" | grep -qE '^  missing  ' \
    && fail "a candidate must not be presented as a finding: $out"
  pass "a capped listing keeps its counts and marks which way each can be wrong"
}

# Absence from a listing is what EVERY way a listing can fail looks like, so a
# gap may not rest on it. The listing proposes; a direct read decides.
test_a_gap_rests_on_a_direct_read_rather_than_on_the_listing() {
  local home out slug
  home=$(make_home audit-verified)
  seed_manifest "$home" ship-a "Add the widget"
  seed_manifest "$home" ship-b "Fix the drain"
  cap "$home" backfill >/dev/null 2>&1 || fail "backfill must deliver both tasks"

  # A listing that drops a page the index still serves reads exactly like a
  # deleted page. The direct read is what tells them apart.
  slug=$(cap "$home" status --json | jq -r '.documents[] | select(.source.id == "ship-b") | .slug')
  out=$(FM_TEST_LIST_OMIT=ship-b cap "$home" audit 2>&1) \
    && fail "a listing that dropped a served page must exit non-zero"
  printf '%s' "$out" | grep -q 'state      gap' \
    && fail "a page the brain still serves must never be reported missing: $out"
  printf '%s' "$out" | grep -q 'state      inconclusive' \
    || fail "a listing proved wrong must be inconclusive: $out"
  printf '%s' "$out" | grep -q 'still serves' \
    || fail "the detail must name the listing as the untrustworthy side: $out"

  # A listing whose rows carry no slug at all is the same class, and it is the
  # one that would otherwise name every captured document as absent.
  out=$(FM_TEST_LIST_GARBLE=1 cap "$home" audit 2>&1) \
    && fail "a listing with no parseable rows must exit non-zero"
  printf '%s' "$out" | grep -q 'state      gap' \
    && fail "an unparseable listing must never become a gap: $out"
  printf '%s' "$out" | grep -q 'state      inconclusive' \
    || fail "an unparseable listing must be inconclusive: $out"

  # A read that could not answer either way is not evidence of absence.
  rm -f "$home/pages/firstmate_"*"_task_ship-b.md"
  out=$(FM_TEST_GET_BROKEN=1 cap "$home" audit 2>&1) \
    && fail "an audit whose reads failed must exit non-zero"
  printf '%s' "$out" | grep -q 'state      gap' \
    && fail "a read that could not answer must never confirm a gap: $out"
  printf '%s' "$out" | grep -q 'state      inconclusive' \
    || fail "an unreadable candidate must be inconclusive: $out"

  # And the finding the audit exists for still lands: the page really is gone,
  # the direct read says so, and the gap names it.
  out=$(cap "$home" audit 2>&1) && fail "a genuinely deleted page must exit non-zero"
  printf '%s' "$out" | grep -q 'state      gap' || fail "a deleted page must still be a gap: $out"
  printf '%s' "$out" | grep -qF "$slug" || fail "the gap must name the deleted page: $out"
  jq -e '.state == "gap" and .missing == 1 and .bounds.missing == "exact"' \
    "$home/state/.gbrain-audit" >/dev/null \
    || fail "a verified gap must record an exact count: $(cat "$home/state/.gbrain-audit")"
  pass "a gap rests on a direct read rather than on absence from the listing"
}

test_a_candidate_set_past_the_probe_ceiling_is_refused_rather_than_verified() {
  local home out
  home=$(make_home audit-probe-cap)
  seed_manifest "$home" ship-a "Add the widget"
  seed_manifest "$home" ship-b "Fix the drain"
  cap "$home" backfill >/dev/null 2>&1 || fail "backfill must deliver both tasks"

  # A listing that named nothing makes every captured document a candidate. A
  # candidate set that large is better evidence that the listing is wrong than
  # that the pages are gone, so it is refused rather than read one page at a time.
  out=$(FM_TEST_LIST_GARBLE=1 FM_GBRAIN_CAPTURE_AUDIT_MAX_PROBES=1 cap "$home" audit 2>&1) \
    && fail "a candidate set past the ceiling must exit non-zero"
  printf '%s' "$out" | grep -q 'state      inconclusive' \
    || fail "an oversized candidate set must be inconclusive: $out"
  printf '%s' "$out" | grep -q 'FM_GBRAIN_CAPTURE_AUDIT_MAX_PROBES' \
    || fail "the detail must name the ceiling that stopped it: $out"
  jq -e '.state == "inconclusive" and .bounds.missing == "at-most" and .bounds.active == "at-least"' \
    "$home/state/.gbrain-audit" >/dev/null \
    || fail "a refused verification must still bound what it measured: $(cat "$home/state/.gbrain-audit")"
  pass "a candidate set past the probe ceiling is refused rather than verified"
}

# --- our own rewrites are not the source changing ---------------------------

# The truncation marker is part of the stored body, and the stored body is what
# decides whether a page needs rewriting - so this pipeline can move a body
# nobody edited. What the refreshed line claims is that the SOURCE changed, so
# it fires from a fingerprint of the durable source instead.
test_a_body_this_pipeline_rewrote_is_not_named_as_a_source_change() {
  local home page out before after
  home=$(make_home source-fingerprint)
  seed_manifest "$home" scout-a "Investigate the drain"
  {
    printf '# Report\n\n'
    awk 'BEGIN { while (i++ < 200) print "the cache key is off by one" }'
  } | seed_report "$home" scout-a
  cap "$home" task scout-a --require-brain >/dev/null || fail "capture must succeed"
  page=$(find "$home/pages" -name '*.md' | head -1)
  grep -q 'Capture truncated at' "$page" && fail "the first capture must not have been cut"
  before=$(item_field "$home" scout-a '.source_version')
  { [ -n "$before" ] && [ "$before" != null ]; } \
    || fail "a captured task must record what it was captured from"

  # The cap moves, so OUR marker rewrites the stored body while the report on
  # disk is byte for byte what it was.
  out=$(FM_GBRAIN_CAPTURE_MAX_BYTES=800 cap "$home" sweep --force 2>&1) || true
  printf '%s' "$out" | grep -q '^refreshed ' \
    && fail "a body this pipeline rewrote must not be named as a source change: $out"
  grep -q 'Capture truncated at' "$page" \
    || fail "the page must still be corrected, silently"
  [ "$(item_field "$home" scout-a '.truncated')" = true ] || fail "the record must say it was cut"
  after=$(item_field "$home" scout-a '.source_version')
  [ "$before" = "$after" ] || fail "an untouched source must keep its fingerprint: $before -> $after"

  # The positive counterpart on the same record: an edited report IS a source
  # change, and the sweep that delivers it says so.
  printf '\nVOIDED: that finding was wrong.\n' >> "$home/data/scout-a/report.md"
  out=$(cap "$home" sweep --force 2>&1) && fail "a sweep that refreshed a page must exit non-zero"
  printf '%s' "$out" | grep -q 'refreshed scout-a' \
    || fail "an edited report must still be named: $out"
  grep -q 'VOIDED' "$page" || fail "the named refresh must be true on the page"
  [ "$(item_field "$home" scout-a '.source_version')" = "$before" ] \
    && fail "an edited report must move the source fingerprint"
  pass "a body this pipeline rewrote is re-delivered without claiming the source changed"
}

# --- the periodic refresh ---------------------------------------------------

test_a_report_edited_after_capture_is_refreshed_by_the_sweep() {
  local home page out
  home=$(make_home sweep)
  seed_manifest "$home" scout-a "Investigate the drain"
  printf '# Report\n\nthe cache key is off by one\n' | seed_report "$home" scout-a
  cap "$home" task scout-a --require-brain >/dev/null || fail "capture must succeed"
  page=$(find "$home/pages" -name '*.md' | head -1)
  grep -q 'off by one' "$page" || fail "the first capture must carry the finding"

  # The defect this closes: the report is edited after cleanup already ran, so
  # nothing about the edit ever reaches capture again.
  printf '\nVOIDED: that finding was wrong.\n' >> "$home/data/scout-a/report.md"
  out=$(cap "$home" sweep --force 2>&1) && fail "a sweep that refreshed a page must exit non-zero"
  printf '%s' "$out" | grep -q 'refreshed scout-a' || fail "the sweep must name what it refreshed: $out"
  grep -q 'VOIDED' "$page" || fail "the sweep must re-deliver the edited body to the same page"
  [ "$(pages_count "$home")" = 1 ] || fail "a refresh must update the page, not add one"

  # Nothing changed since: the sweep is silent and says so by exiting 0.
  cap "$home" sweep --force >/dev/null 2>&1 || fail "a sweep with nothing to correct must be silent"
  pass "a report edited after capture is refreshed onto the same page"
}

# A `refreshed <task>` line is relayed verbatim by a session start and read
# there as completed work - the page a search returns is true again. So it is a
# claim about a delivery, not about a recomposition, and a sweep that could not
# deliver must not make it. The mirror matters as much: a delivery that lands a
# sweep later is still the correction of a page that had been serving a voided
# conclusion, so it must be named then rather than corrected in silence. The
# whole point of this change is a record that does not lie about its own state,
# in either direction.
test_a_refresh_is_named_once_on_the_sweep_that_delivers_it() {
  local home page out
  home=$(make_home sweep-refused)
  seed_manifest "$home" scout-a "Investigate the drain"
  printf '# Report\n\nthe cache key is off by one\n' | seed_report "$home" scout-a
  cap "$home" task scout-a --require-brain >/dev/null || fail "capture must succeed"
  page=$(find "$home/pages" -name '*.md' | head -1)
  [ -n "$page" ] || fail "the first capture must have produced a page"

  printf '\nVOIDED: that finding was wrong.\n' >> "$home/data/scout-a/report.md"
  fake_gbrain "$home" fail
  out=$(cap "$home" sweep --force 2>&1) && fail "a sweep that could not deliver must exit non-zero"
  printf '%s' "$out" | grep -q '^refreshed ' \
    && fail "a sweep whose delivery failed must not claim it refreshed a page: $out"
  grep -q 'VOIDED' "$page" \
    && fail "the page must still be serving the stale body, which is what makes the claim false"
  printf '%s' "$out" | grep -q 'reported errors' \
    || fail "a sweep that could not deliver must still report the failure: $out"

  # The summary total is the same claim in another form, so it has to agree
  # with the lines: nothing delivered, nothing counted as corrected.
  out=$(cap "$home" backfill 2>&1)
  printf '%s' "$out" | grep -q '^refreshed ' && fail "backfill must not name an undelivered refresh: $out"
  printf '%s' "$out" | grep -q 'refreshed=0' || fail "the refreshed total must count only deliveries: $out"

  # The drift is not forgotten by the failure that delayed it. The record
  # remembers what the index was last given, so the sweep that finally delivers
  # is the one that names it - a page corrected in silence would leave a captain
  # never told that a search had been returning a voided conclusion.
  fake_gbrain "$home" ok
  out=$(cap "$home" sweep --force 2>&1) && fail "the sweep that delivered the refresh must exit non-zero"
  [ "$(printf '%s\n' "$out" | grep -c '^refreshed scout-a')" = 1 ] \
    || fail "the sweep that delivered a delayed refresh must name it exactly once: $out"
  grep -q 'VOIDED' "$page" || fail "a named refresh must be true on the page it names"
  [ "$(pages_count "$home")" = 1 ] || fail "a refresh must update the page, not add one"

  # And exactly once: nothing has drifted since, so the next sweep is silent.
  out=$(cap "$home" sweep --force 2>&1) || fail "a sweep with nothing to correct must exit 0"
  [ -z "$out" ] || fail "a page already refreshed must not be named again: $out"

  # The counter cannot become unconditional either: a page the index was never
  # given is a first capture however often its report was edited on the way
  # there, and naming that as a correction would be the same lie in reverse.
  seed_manifest "$home" scout-b "Investigate the cache"
  printf '# Report\n\nfirst draft\n' | seed_report "$home" scout-b
  fake_gbrain "$home" fail
  cap "$home" sweep --force >/dev/null 2>&1 || true
  printf '\nsecond draft\n' >> "$home/data/scout-b/report.md"
  fake_gbrain "$home" ok
  out=$(cap "$home" sweep --force 2>&1) || fail "the sweep that captured it must exit 0"
  printf '%s' "$out" | grep -q '^refreshed ' \
    && fail "a page that was never delivered must not be named as refreshed: $out"
  [ -z "$out" ] || fail "a first capture must leave the sweep silent: $out"
  grep -q 'second draft' "$home/pages/"*task_scout-b.md \
    || fail "the first capture must still carry the edited body"
  pass "a sweep names a refreshed page once, on the sweep that delivers it"
}

test_the_sweep_runs_on_its_interval_and_is_inert_without_a_brain() {
  local home out
  home=$(make_home sweep-interval)
  seed_manifest "$home" scout-a "Investigate the drain"
  printf '# Report\n\nfirst\n' | seed_report "$home" scout-a
  cap "$home" task scout-a --require-brain >/dev/null || fail "capture must succeed"
  cap "$home" sweep --force >/dev/null 2>&1 || true
  [ -f "$home/state/.gbrain-capture-sweep" ] || fail "a sweep must stamp its interval"

  # Inside the interval the sweep does not run at all, so a session start can
  # arm it unconditionally without paying for it every time.
  printf '\nsecond\n' >> "$home/data/scout-a/report.md"
  out=$(cap "$home" sweep 2>&1) || fail "a sweep inside its interval must be silent"
  [ -z "$out" ] || fail "a sweep inside its interval must print nothing: $out"
  out=$(cap "$home" sweep --interval 0 2>&1) && fail "an elapsed interval must run the sweep"
  printf '%s' "$out" | grep -q 'refreshed scout-a' || fail "the elapsed sweep must refresh: $out"

  # A home with no brain is untouched: no output, and no new files.
  home=$(make_home sweep-nobrain --no-brain)
  seed_manifest "$home" ship-a "Add the widget"
  out=$(cap "$home" sweep --force 2>&1) || fail "a sweep without a brain must exit 0"
  [ -z "$out" ] || fail "a sweep without a brain must print nothing: $out"
  [ ! -e "$home/state/.gbrain-capture-sweep" ] || fail "a home with no brain must get no sweep marker"
  [ ! -e "$home/state/.gbrain-audit" ] || fail "a home with no brain must get no audit record"
  [ ! -d "$home/data/gbrain-outbox" ] || fail "a home with no brain must create no outbox"
  pass "the sweep respects its interval and stays inert without a brain"
}

test_capture_is_inert_without_a_brain
test_representative_secrets_are_redacted_before_they_reach_disk
test_an_unterminated_private_key_is_refused_rather_than_stored
test_a_terminated_private_key_block_is_replaced
test_a_title_carrying_a_backslash_stays_valid_frontmatter
test_an_out_of_shape_document_id_is_refused_before_it_becomes_a_path
test_capture_never_reads_a_brief_or_a_credential_store
test_identity_is_deterministic_and_delivery_is_idempotent
test_two_homes_never_share_a_document
test_a_stopped_brain_leaves_a_durable_pending_item
test_delivery_is_bounded_and_leaves_the_item_pending
test_retry_is_bounded_and_force_resumes_it
test_a_partially_written_record_is_reported_not_believed
test_backfill_is_restartable_and_reports_counts
test_backfill_records_a_refusal_without_stopping
test_a_truncated_body_is_marked_rather_than_left_looking_complete
test_the_audit_names_a_captured_document_the_index_no_longer_serves
test_an_index_listing_that_could_not_be_read_is_not_reported_as_a_gap
test_a_listing_that_fails_without_a_message_is_still_inconclusive
test_a_capped_listing_keeps_its_counts_as_bounds
test_a_gap_rests_on_a_direct_read_rather_than_on_the_listing
test_a_candidate_set_past_the_probe_ceiling_is_refused_rather_than_verified
test_a_body_this_pipeline_rewrote_is_not_named_as_a_source_change
test_a_report_edited_after_capture_is_refreshed_by_the_sweep
test_a_refresh_is_named_once_on_the_sweep_that_delivers_it
test_the_sweep_runs_on_its_interval_and_is_inert_without_a_brain
test_status_reports_archived_pending_skipped_and_redacted
test_a_note_goes_through_the_same_path
test_teardown_captures_and_the_manifest_carries_the_receipt
test_teardown_leaves_the_manifest_agreeing_with_the_captured_body
test_teardown_is_never_blocked_by_the_brain
test_teardown_in_a_home_without_a_brain_is_unchanged

echo "all fm-gbrain-capture tests passed"
