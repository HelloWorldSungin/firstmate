#!/usr/bin/env bash
# Live proof that captured task knowledge is actually RETRIEVABLE from a real
# GBrain brain, and that recapturing one task updates one page.
#
# The portable suite proves the parts Firstmate owns - redaction before enqueue,
# durable outbox, bounded delivery, deterministic identity - against a stub. It
# cannot prove the part GBrain owns: that supplying a slug upserts rather than
# accumulates, that a captured page comes back by that slug, and that the page
# a delivery reports is the page a later read finds. A stub would only confirm
# the assumption already written into the stub, so that half is proved here.
#
# Opt-in, because it needs a GBrain installation and a local embedding endpoint
# that standard CI has neither of. Every brain and home it creates is disposable
# and confined to a temp root; it never touches the operator's own GBRAIN_HOME,
# brain, or ~/.gbrain.
set -u

if [ "${FM_GBRAIN_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GBRAIN_LIVE_E2E=1 to run the live GBrain capture proof"
  exit 0
fi

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GBRAIN_BIN="${FM_GBRAIN_BIN:-gbrain}"
command -v "$GBRAIN_BIN" >/dev/null 2>&1 || { echo "skip: gbrain not found (set FM_GBRAIN_BIN)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

EMBED_URL="${FM_GBRAIN_EMBED_URL:-http://127.0.0.1:11434/v1}"
EMBED_MODEL="${FM_GBRAIN_EMBED_MODEL:-ollama:snowflake-arctic-embed2:568m}"
EMBED_DIMS="${FM_GBRAIN_EMBED_DIMS:-1024}"
curl -sf -m 5 "${EMBED_URL%/}/models" >/dev/null 2>&1 \
  || { echo "skip: no local embedding endpoint at $EMBED_URL"; exit 0; }

CAPTURE="$ROOT/bin/fm-gbrain-capture.sh"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-capture-e2e)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"

cap() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_GBRAIN_BIN="$GBRAIN_BIN" \
    "$CAPTURE" "$@"
}

brain() {  # run gbrain against the disposable brain this test built
  GBRAIN_HOME="$HOME_DIR/data/gbrain/runtime" OLLAMA_BASE_URL="$EMBED_URL" "$GBRAIN_BIN" "$@"
}

# The home's own brain, at exactly the location bin/fm-gbrain-lib.sh derives.
jq -n --arg u "$EMBED_URL" --arg m "$EMBED_MODEL" --argjson d "$EMBED_DIMS" \
  '{version: 1, local: {embedding_base_url: $u, embedding_model: $m, embedding_dimensions: $d}}' \
  > "$HOME_DIR/config/gbrain.json"
mkdir -p "$HOME_DIR/data/gbrain/runtime"
GBRAIN_HOME="$HOME_DIR/data/gbrain/runtime" OLLAMA_BASE_URL="$EMBED_URL" \
  "$GBRAIN_BIN" init --pglite --path "$HOME_DIR/data/gbrain/pglite" \
  --embedding-model "$EMBED_MODEL" --embedding-dimensions "$EMBED_DIMS" \
  --non-interactive >/dev/null 2>&1 \
  || { echo "skip: could not initialize a disposable brain"; exit 0; }

mkdir -p "$HOME_DIR/data/ship-live"
jq -n '{
  schema: "fm-outcome-manifest.v1", task_id: "ship-live",
  title: "Bound the reranker input", project: "/projects/widget",
  kind: "ship", mode: "no-mistakes",
  outcome: {state: "done", detail: "landed"},
  timestamps: {completed: "2026-08-04T10:00:00Z"},
  pr: {url: "https://github.com/acme/widget/pull/9"},
  work_items: {references: []}
}' > "$HOME_DIR/data/ship-live/outcome.json"
cat > "$HOME_DIR/data/ship-live/report.md" <<'EOF'
# Findings

The reranker returns HTTP 500 beyond its 4096-token context, and GBrain then
falls back to the non-reranked ordering. Treat that as a failed rerank.
EOF

test_capture_is_retrievable_from_the_real_brain() {
  local slug got
  cap task ship-live --require-brain --timeout 120 >/dev/null \
    || fail "capture into a real brain must succeed"
  slug=$(sed -n 's/^receipt=//p' "$HOME_DIR/state/ship-live.gbrain")
  [ -n "$slug" ] || fail "the receipt must name the page"

  # The whole point of the story: retrieval by the receipt the durable manifest
  # carries, from the brain rather than from any Firstmate record.
  got=$(brain get "$slug" 2>&1) || fail "the captured page must be readable: $got"
  printf '%s' "$got" | grep -q 'non-reranked ordering' \
    || fail "the retrieved page must carry the task's knowledge: $got"
  printf '%s' "$got" | grep -q 'ship-live' || fail "the retrieved page must identify its task"
  pass "a captured task is retrievable from a real brain by the receipt the manifest carries"
}

test_recapture_updates_one_page() {
  local slug before after
  slug=$(sed -n 's/^receipt=//p' "$HOME_DIR/state/ship-live.gbrain")
  before=$(brain list --limit 100 2>/dev/null | grep -c "$slug" || true)
  cat >> "$HOME_DIR/data/ship-live/report.md" <<'EOF'

The bound was later raised, and the fallback ordering stopped appearing.
EOF
  cap task ship-live --require-brain --timeout 120 >/dev/null || fail "recapture must succeed"
  after=$(brain list --limit 100 2>/dev/null | grep -c "$slug" || true)
  [ "$before" = "$after" ] || fail "recapture created a second page ($before -> $after)"
  brain get "$slug" 2>/dev/null | grep -q 'stopped appearing' \
    || fail "the one page must carry the new revision"
  pass "recapturing a changed task updates the same page instead of accumulating copies"
}

test_the_task_survives_its_volatile_records() {
  local slug
  slug=$(sed -n 's/^receipt=//p' "$HOME_DIR/state/ship-live.gbrain")
  # Exactly what teardown leaves behind: the durable manifest, no volatile state.
  rm -f "$HOME_DIR/state/ship-live.gbrain"
  rm -rf "$HOME_DIR/data/ship-live/report.md"
  brain get "$slug" 2>/dev/null | grep -q 'non-reranked ordering' \
    || fail "the knowledge must survive the removal of its volatile records"
  pass "the captured knowledge outlives the task's own records"
}

# The audit's verdict comes from GBrain's own page listing and from what a
# soft-delete does to it. A stub can only confirm the assumption written into
# the stub, so the case that matters - a record still marked captured whose page
# has left ordinary retrieval - is proved against the real binary here.
test_the_audit_sees_a_page_that_left_the_index() {
  local slug out
  slug=$(cap status --json | jq -r '.documents[] | select(.source.id == "ship-live") | .slug')
  [ -n "$slug" ] || fail "the stored record must name its page"
  out=$(cap audit --timeout 120 2>&1) || fail "an audit with the page served must pass: $out"
  printf '%s' "$out" | grep -q 'state      ok' || fail "a matching audit must read ok: $out"

  brain delete "$slug" >/dev/null 2>&1 || fail "the disposable page must be deletable"

  # The pair the audit's verdict rests on, proved against the real binary rather
  # than against an assumption written into a stub. Every gbrain failure exits
  # 1 - a page that is not there, a brain that is not there, an index that will
  # not open - so a failing read carries no information at all. Only the second
  # read SUCCEEDING distinguishes a soft-deleted page from a brain that cannot
  # answer, and only a working brain can produce it.
  brain get "$slug" >/dev/null 2>&1 \
    && fail "ordinary retrieval must stop serving a soft-deleted page"
  brain get "$slug" --include-deleted 2>/dev/null | grep -q 'non-reranked ordering' \
    || fail "the store must still return a soft-deleted page under --include-deleted"
  brain get "firstmate/never-captured-zzz/task/nope" --include-deleted >/dev/null 2>&1 \
    && fail "a slug that was never captured must not be returned by either read"
  # The store answers a page that is not there and a brain that is not there
  # with the same status, which is why the verdict may never be read off one.
  brain get "firstmate/never-captured-zzz/task/nope" >/dev/null 2>&1
  [ "$?" = 1 ] || fail "gbrain must answer a missing page with its universal failure status"
  GBRAIN_HOME="$TMP_ROOT/no-such-brain" "$GBRAIN_BIN" get "$slug" >/dev/null 2>&1
  [ "$?" = 1 ] || fail "gbrain must answer a missing brain with that same status"

  out=$(cap audit --timeout 120 2>&1) && fail "an audit that found a gap must exit non-zero"
  printf '%s' "$out" | grep -q 'state      gap' || fail "a deleted page must read as a gap: $out"
  printf '%s' "$out" | grep -qF "$slug" || fail "the audit must name the missing page: $out"

  # And the repair closes it, from the same durable record.
  cap process --document "$(cap status --json | jq -r '.documents[] | select(.source.id == "ship-live") | .document_id')" \
    --force --timeout 120 >/dev/null || fail "re-delivery must succeed"
  out=$(cap audit --timeout 120 2>&1) || true
  printf '%s' "$out" | grep -q 'state      ok' \
    || fail "re-delivering the record must close the gap: $out"
  pass "the audit sees a page that left the real index, and sees the repair close it"
}

test_capture_is_retrievable_from_the_real_brain
test_recapture_updates_one_page
test_the_task_survives_its_volatile_records
test_the_audit_sees_a_page_that_left_the_index

echo "all fm-gbrain-capture-e2e tests passed"
