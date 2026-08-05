#!/usr/bin/env bash
# Behavior tests for bin/fm-model-verify.sh - the helper that checks the model a
# dispatched worker ACTUALLY ran on against the model firstmate RECORDED for it
# in state/<id>.meta.
#
# The record is what was REQUESTED, sometimes after a quota-balanced choice. The
# evidence is what the runtime WROTE. These cases pin every branch of that
# comparison hermetically, over a throwaway home and a throwaway claude config
# store, with no live fleet state and no real harness:
#   (a) a family alias matches any member of that family, suffix and all
#   (b) a pinned specific model matches only itself
#   (c) a downgrade below the dispatched family is a mismatch
#   (d) a mid-dispatch model change is a mismatch even when one value matches
#   (e) evidence that cannot be located or read is LOUD, never a quiet pass, and
#       an absent session (`unstarted`) is distinguished from unreadable evidence
#   (f) `pending` (nothing to compare yet) and `unpinned` (nothing promised) are
#       distinct no-verdict outcomes and never render as `match`
#   (g) spawned_at binds evidence to THIS dispatch, so a reused worktree's
#       previous occupant can neither be attributed to it nor silently ignored
#   (h) --all reports every task and exits on the worst verdict
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-model-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-verify)

# A throwaway home plus a throwaway claude config store. CLAUDE_CONFIG_DIR is
# the same knob bin/fm-spawn.sh forwards onto a real crewmate launch, so the
# fixture reads exactly the way production does.
HOME_DIR="$TMP_ROOT/home"
CFG="$TMP_ROOT/claude"
mkdir -p "$HOME_DIR/state" "$CFG/projects"
export CLAUDE_CONFIG_DIR="$CFG"

# encoded_dir <cwd>: claude's transcript directory for a working directory.
# Every character outside [A-Za-z0-9] becomes '-'.
encoded_dir() {
  printf '%s/projects/%s' "$CFG" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
}

# write_transcript <cwd> <session> <model>...: one JSONL transcript recording an
# assistant turn per model, in the shape the runtime writes.
write_transcript() {
  local cwd=$1 session=$2 dir model
  shift 2
  dir=$(encoded_dir "$cwd")
  mkdir -p "$dir"
  : > "$dir/$session.jsonl"
  for model in "$@"; do
    printf '{"type":"assistant","message":{"model":"%s"}}\n' "$model" >> "$dir/$session.jsonl"
  done
}

# meta <id> <model> [extra-key=value]...: a dispatch record for a claude worker
# in its own worktree under the throwaway home.
meta() {
  local id=$1 model=$2 wt
  shift 2
  wt="$TMP_ROOT/wt/$id"
  mkdir -p "$wt"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "project=$TMP_ROOT/clone" \
    "harness=claude" \
    "kind=ship" \
    "model=$model" \
    "model_evidence_store=$CFG" \
    "$@"
  printf '%s' "$wt"
}

run_verify() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$VERIFY" "$@" 2>&1
}

run_verify_with_path() {
  local path=$1
  shift
  PATH="$path:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$VERIFY" "$@" 2>&1
}

test_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# --- (a) family alias matches any member of that family ---------------------

wt=$(meta alias-match opus)
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify alias-match); code=$?
expect_code 0 "$code" "alias match exits 0"
assert_contains "$out" "verdict: match" "an opus-family model satisfies a recorded 'opus'"
assert_contains "$out" "actual: claude-opus-5" "the actual model is reported verbatim"
pass "family alias matches a member of its family"

# The runtime appends a context-window suffix; it names the same model.
wt=$(meta suffix-match opus)
write_transcript "$wt" s1 'claude-opus-5[1m]'
out=$(run_verify suffix-match); code=$?
expect_code 0 "$code" "suffixed model exits 0"
assert_contains "$out" "verdict: match" "a [1m] context suffix does not make a model a different model"
pass "context-window suffix does not fake a mismatch"

# --- (b) a pinned specific model matches only itself ------------------------

wt=$(meta pinned-match claude-opus-4-8)
write_transcript "$wt" s1 claude-opus-4-8
out=$(run_verify pinned-match); code=$?
expect_code 0 "$code" "pinned exact match exits 0"
assert_contains "$out" "verdict: match" "a pinned model matches itself"
pass "pinned specific model matches itself"

# Same family, different version: the record promised a version, so this is not
# what was dispatched.
wt=$(meta pinned-version-drift claude-opus-4-8)
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify pinned-version-drift); code=$?
expect_code 3 "$code" "version drift under a pinned model exits 3"
assert_contains "$out" "verdict: mismatch" "a pinned version is not satisfied by another version"
pass "pinned model rejects a different version of the same family"

# --- (c) a downgrade below the dispatched family ----------------------------

wt=$(meta downgrade opus)
write_transcript "$wt" s1 claude-sonnet-5
out=$(run_verify downgrade); code=$?
expect_code 3 "$code" "silent downgrade exits 3"
assert_contains "$out" "verdict: mismatch" "sonnet does not satisfy a dispatched opus"
assert_contains "$out" "dispatched as 'opus' but ran on claude-sonnet-5" "the mismatch names both models"
pass "silent downgrade below the dispatched family is detected"

# --- (d) a mid-dispatch model change ----------------------------------------
#
# One value matching must never absolve the other: this is the case where a
# worker starts on the dispatched tier and is later served by another.

wt=$(meta mid-change opus spawned_at=1)
write_transcript "$wt" s1 claude-opus-5
write_transcript "$wt" s2 claude-sonnet-5
out=$(run_verify mid-change); code=$?
expect_code 3 "$code" "a partial match still exits 3"
assert_contains "$out" "verdict: mismatch" "a later downgrade is not excused by an earlier correct turn"
assert_contains "$out" "claude-sonnet-5" "the deviating model is named"
pass "mid-dispatch model change is detected"

# --- (e) evidence that cannot be located or read is loud --------------------

# An absent transcript directory means the runtime wrote no session for this
# worker at all. That is still no verdict and still exits 4, but it is a
# distinct cause from evidence that exists and cannot be read, so it carries its
# own verdict rather than being folded into `unverifiable`.
fresh_store="$TMP_ROOT/fresh-claude-store"
mkdir -p "$fresh_store"
meta fresh-store opus >/dev/null
sed -i.bak "s|^model_evidence_store=.*$|model_evidence_store=$fresh_store|" "$HOME_DIR/state/fresh-store.meta"
rm -f "$HOME_DIR/state/fresh-store.meta.bak"
out=$(run_verify fresh-store); code=$?
expect_code 4 "$code" "fresh evidence store exits 4"
assert_contains "$out" "verdict: unstarted" "a fresh store without a transcript parent is unstarted"
assert_not_contains "$out" "verdict: unverifiable" "a provably absent transcript parent is not unreadable evidence"
assert_contains "$out" "no transcript parent or session" "the fresh-store cause is named"
pass "a fresh inspectable store without a transcript parent is unstarted"

meta no-evidence opus >/dev/null
out=$(run_verify no-evidence); code=$?
expect_code 4 "$code" "missing transcript directory exits 4"
assert_contains "$out" "verdict: unstarted" "a worker whose runtime wrote no session is unstarted"
assert_not_contains "$out" "verdict: unverifiable" "an absent session is not conflated with unreadable evidence"
assert_not_contains "$out" "verdict: match" "unlocatable evidence never reads as a match"
assert_contains "$out" "no evidence of its own to read" "the unstarted reason names its cause"
pass "an absent transcript directory is distinguished from unreadable evidence"
out=$(run_verify no-evidence --terminal); code=$?
expect_code 4 "$code" "terminal verification still rejects an unstarted worker"
assert_contains "$out" "verdict: unstarted" "terminal rejection preserves the unstarted verdict"
pass "terminal verification rejects unstarted as no verdict"

wt=$(meta non-directory-session opus)
dir=$(encoded_dir "$wt")
printf 'not transcript data\n' > "$dir"
out=$(run_verify non-directory-session); code=$?
expect_code 4 "$code" "non-directory transcript path exits 4"
assert_contains "$out" "verdict: unverifiable" "a non-directory transcript path is unverifiable"
assert_not_contains "$out" "verdict: unstarted" "a present transcript path is not treated as absent"
assert_contains "$out" "transcript path is not a directory" "the non-directory cause is named"
pass "a present non-directory transcript path fails loudly"

non_directory_parent_store="$TMP_ROOT/non-directory-parent-store"
mkdir -p "$non_directory_parent_store"
printf 'not a transcript parent\n' > "$non_directory_parent_store/projects"
meta non-directory-parent opus >/dev/null
sed -i.bak "s|^model_evidence_store=.*$|model_evidence_store=$non_directory_parent_store|" "$HOME_DIR/state/non-directory-parent.meta"
rm -f "$HOME_DIR/state/non-directory-parent.meta.bak"
out=$(run_verify non-directory-parent); code=$?
expect_code 4 "$code" "non-directory transcript parent exits 4"
assert_contains "$out" "verdict: unverifiable" "a non-directory transcript parent is unverifiable"
assert_not_contains "$out" "verdict: unstarted" "a present transcript parent path is not treated as absent"
assert_contains "$out" "transcript parent path is not a directory" "the non-directory parent cause is named"
pass "a present non-directory transcript parent fails loudly"

unreadable_store="$TMP_ROOT/unreadable-parent-store"
mkdir -p "$unreadable_store/projects"
wt=$(meta unreadable-parent opus)
sed -i.bak "s|^model_evidence_store=.*$|model_evidence_store=$unreadable_store|" "$HOME_DIR/state/unreadable-parent.meta"
rm -f "$HOME_DIR/state/unreadable-parent.meta.bak"
chmod 000 "$unreadable_store/projects"
out=$(run_verify unreadable-parent); code=$?
chmod 755 "$unreadable_store/projects"
if [ "$(id -u)" = 0 ]; then
  pass "unreadable transcript parent case skipped (running as root)"
else
  expect_code 4 "$code" "unreadable transcript parent exits 4"
  assert_contains "$out" "verdict: unverifiable" "an unreadable transcript parent is unverifiable"
  assert_not_contains "$out" "verdict: unstarted" "a hidden transcript path is not treated as absent"
  assert_contains "$out" "transcript parent directory is not readable" "the unreadable parent cause is named"
  pass "an unreadable transcript parent fails loudly"
fi

missing_store="$TMP_ROOT/missing-claude-store"
meta missing-store opus model_evidence_watermark=claude-transcript-v1 >/dev/null
sed -i.bak "s|^model_evidence_store=.*$|model_evidence_store=$missing_store|" "$HOME_DIR/state/missing-store.meta"
rm -f "$HOME_DIR/state/missing-store.meta.bak"
out=$(run_verify missing-store); code=$?
expect_code 4 "$code" "missing recorded evidence store exits 4"
assert_contains "$out" "verdict: unverifiable" "a missing evidence store remains unverifiable"
assert_not_contains "$out" "verdict: unstarted" "a missing evidence store is not treated as an absent worker session"
assert_contains "$out" "model-evidence store is missing" "the unverifiable reason names the missing store"
pass "a missing recorded evidence store is not mistaken for an unstarted worker"

wt=$(meta legacy-missing-store opus)
sed -i.bak '/^model_evidence_store=/d' "$HOME_DIR/state/legacy-missing-store.meta"
rm -f "$HOME_DIR/state/legacy-missing-store.meta.bak"
out=$(run_verify legacy-missing-store); code=$?
expect_code 4 "$code" "a legacy record without an evidence-store identity exits 4"
assert_contains "$out" "verdict: unarmed" \
  "a legacy record without an evidence-store identity is reported as never armed"
assert_not_contains "$out" "verdict: unstarted" \
  "ambient session absence did not authorize an unstarted verdict"
assert_not_contains "$out" "verdict: match" \
  "an unarmed record manufactured a pass"
assert_contains "$out" "names no model-evidence store" \
  "the unarmed reason names the unknown evidence location"
pass "a missing persisted evidence-store identity never falls back to ambient state"

# `unarmed` is a REPORTING verdict, not an allowance: it stays at the same exit
# severity as every other no-verdict outcome, so a reporting caller keeps
# surfacing it. Only terminal mode, checked below, treats it differently.
out=$(run_verify legacy-missing-store --terminal); code=$?
expect_code 0 "$code" "an unarmed dispatch blocked terminal cleanup"
assert_contains "$out" "verdict: unarmed" \
  "terminal mode dropped the unarmed verdict line"
pass "an unarmed dispatch reports at no-verdict severity and does not block cleanup"

# The enumeration behind that release, pinned executably rather than in prose.
# An absent store line is only the SHAPE of a never-armed record; a record
# carrying positive proof that arming DID run must keep refusing on exactly that
# same absence. capture_claude_watermark emits the store and the watermark
# together, plus its baseline rows, so either marker alone is that proof.
wt=$(meta armed-watermark-no-store opus model_evidence_watermark=claude-transcript-v1)
sed -i.bak '/^model_evidence_store=/d' "$HOME_DIR/state/armed-watermark-no-store.meta"
rm -f "$HOME_DIR/state/armed-watermark-no-store.meta.bak"
out=$(run_verify armed-watermark-no-store); code=$?
expect_code 4 "$code" "an arming watermark without a store exits 4"
assert_contains "$out" "verdict: unverifiable" \
  "an arming watermark without a store was not unverifiable"
assert_not_contains "$out" "verdict: unarmed" \
  "a record proven to have been armed was released as never armed"
assert_contains "$out" "arming markers but names no model-evidence store" \
  "the damaged-armed-record cause is named"
out=$(run_verify armed-watermark-no-store --terminal); code=$?
expect_code 4 "$code" "an arming watermark without a store stopped blocking terminal cleanup"
assert_not_contains "$out" "verdict: unarmed" \
  "terminal mode released a record proven to have been armed"
pass "an arming watermark with no store is a damaged armed record and keeps blocking"

wt=$(meta armed-baseline-no-store opus model_evidence_before=previous.jsonl)
sed -i.bak '/^model_evidence_store=/d' "$HOME_DIR/state/armed-baseline-no-store.meta"
rm -f "$HOME_DIR/state/armed-baseline-no-store.meta.bak"
out=$(run_verify armed-baseline-no-store); code=$?
expect_code 4 "$code" "a baseline identity without a store exits 4"
assert_contains "$out" "verdict: unverifiable" \
  "a baseline identity without a store was not unverifiable"
assert_not_contains "$out" "verdict: unarmed" \
  "a record carrying a captured baseline was released as never armed"
out=$(run_verify armed-baseline-no-store --terminal); code=$?
expect_code 4 "$code" "a baseline identity without a store stopped blocking terminal cleanup"
assert_not_contains "$out" "verdict: unarmed" \
  "terminal mode released a record carrying a captured baseline"
pass "a captured baseline with no store is a damaged armed record and keeps blocking"

# The third record shape reaching the store-absent branch: a remote secondmate
# route record. bin/fm-spawn.sh's spawn_remote_secondmate writes kind=secondmate
# with the remote route fields and no store line for a secondmate that DID
# launch and run; its armed record lives in the remote host's own state, so the
# evidence is not absent, only unreadable from this home.
wt=$(meta remote-secondmate-route opus)
sed -i.bak -e '/^model_evidence_store=/d' -e 's|^kind=.*$|kind=secondmate|' \
  "$HOME_DIR/state/remote-secondmate-route.meta"
rm -f "$HOME_DIR/state/remote-secondmate-route.meta.bak"
printf '%s\n' \
  "home=$wt" \
  'remote_host=builder.example' \
  'remote_root=/srv/clone' \
  'remote_backend=tmux' \
  'remote_target=firstmate:fm-remote-secondmate-route' \
  >> "$HOME_DIR/state/remote-secondmate-route.meta"
out=$(run_verify remote-secondmate-route); code=$?
expect_code 4 "$code" "a remote secondmate route record exits 4"
assert_contains "$out" "verdict: unverifiable" \
  "a remote secondmate route record was not unverifiable"
assert_not_contains "$out" "verdict: unarmed" \
  "a secondmate that ran on a remote host was released as never armed"
assert_contains "$out" "ran on a remote host" \
  "the ran-elsewhere cause is named"
out=$(run_verify remote-secondmate-route --terminal); code=$?
expect_code 4 "$code" "a remote secondmate route record stopped blocking terminal cleanup"
assert_not_contains "$out" "verdict: unarmed" \
  "terminal mode released a secondmate that ran on a remote host"
pass "a remote secondmate route record ran elsewhere and keeps blocking"

# The boundary that must not move: an armed dispatch keeps blocking terminal
# cleanup on every one of its failure modes. Same fixture, one line repointed.
wt=$(meta armed-store-absent opus model_evidence_watermark=claude-transcript-v1)
sed -i.bak "s|^model_evidence_store=.*$|model_evidence_store=$TMP_ROOT/armed-but-absent|" \
  "$HOME_DIR/state/armed-store-absent.meta"
rm -f "$HOME_DIR/state/armed-store-absent.meta.bak"
out=$(run_verify armed-store-absent --terminal); code=$?
expect_code 4 "$code" "an armed dispatch whose store is gone stopped blocking cleanup"
assert_contains "$out" "verdict: unverifiable" \
  "an armed dispatch whose store is gone was not unverifiable"
assert_not_contains "$out" "verdict: unarmed" \
  "a recorded-but-missing store was misreported as never armed"
assert_contains "$out" "model-evidence store is missing" \
  "the missing-store cause is named"
pass "a recorded evidence store that is gone from disk still blocks terminal cleanup"

# A store that EXISTS and cannot be read is a different failure from one that is
# gone, so terminal mode is pinned on it separately.
armed_unreadable_store="$TMP_ROOT/armed-unreadable-store"
mkdir -p "$armed_unreadable_store"
wt=$(meta armed-store-unreadable opus model_evidence_watermark=claude-transcript-v1)
sed -i.bak "s|^model_evidence_store=.*$|model_evidence_store=$armed_unreadable_store|" \
  "$HOME_DIR/state/armed-store-unreadable.meta"
rm -f "$HOME_DIR/state/armed-store-unreadable.meta.bak"
chmod 000 "$armed_unreadable_store"
out=$(run_verify armed-store-unreadable --terminal); code=$?
chmod 755 "$armed_unreadable_store"
if [ "$(id -u)" = 0 ]; then
  pass "unreadable evidence store case skipped (running as root)"
else
  expect_code 4 "$code" "an armed dispatch with an unreadable store stopped blocking cleanup"
  assert_contains "$out" "verdict: unverifiable" \
    "an armed dispatch with an unreadable store was not unverifiable"
  assert_not_contains "$out" "verdict: unarmed" \
    "a recorded-but-unreadable store was misreported as never armed"
  assert_contains "$out" "model-evidence store is not readable" \
    "the unreadable-store cause is named"
  pass "a recorded evidence store that cannot be read still blocks terminal cleanup"
fi

# A store line that is present and malformed is a damaged armed record, not an
# unarmed one, so it keeps the blocking verdict rather than the allowance.
wt=$(meta armed-store-malformed opus)
sed -i.bak 's|^model_evidence_store=.*$|model_evidence_store=relative/not/absolute|' \
  "$HOME_DIR/state/armed-store-malformed.meta"
rm -f "$HOME_DIR/state/armed-store-malformed.meta.bak"
out=$(run_verify armed-store-malformed --terminal); code=$?
expect_code 4 "$code" "a malformed recorded store stopped blocking cleanup"
assert_contains "$out" "verdict: unverifiable" \
  "a malformed recorded store was not unverifiable"
assert_not_contains "$out" "verdict: unarmed" \
  "a malformed recorded store was misreported as never armed"
pass "a malformed recorded evidence store still blocks terminal cleanup"

out=$(run_verify never-dispatched); code=$?
expect_code 4 "$code" "absent durable record exits 4"
assert_contains "$out" "verdict: unverifiable" "no record means no verdict, loudly"
pass "absent durable record fails loudly"

wt=$(meta missing-model opus)
sed -i.bak '/^model=/d' "$HOME_DIR/state/missing-model.meta"
rm -f "$HOME_DIR/state/missing-model.meta.bak"
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify missing-model); code=$?
expect_code 4 "$code" "missing model record exits 4"
assert_contains "$out" "verdict: unverifiable" "a missing model record is not unpinned"
assert_not_contains "$out" "verdict: unpinned" "only model=default is unpinned"
pass "missing model metadata fails loudly"

# A harness with no verified evidence source must say so rather than pass.
wt=$(meta other-harness opus)
sed -i.bak 's/^harness=claude$/harness=codex/' "$HOME_DIR/state/other-harness.meta"
rm -f "$HOME_DIR/state/other-harness.meta.bak"
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify other-harness); code=$?
expect_code 4 "$code" "unsupported harness exits 4"
assert_contains "$out" "verdict: unverifiable" "a harness with no evidence adapter is unverifiable"
assert_contains "$out" "codex" "the unverifiable reason names the harness"
pass "a harness with no verified evidence source fails loudly"

# An unreadable transcript directory is a read failure, not a clean worker.
wt=$(meta unreadable opus)
dir=$(encoded_dir "$wt")
mkdir -p "$dir"
write_transcript "$wt" s1 claude-opus-5
chmod 000 "$dir"
out=$(run_verify unreadable); code=$?
chmod 755 "$dir"
if [ "$(id -u)" = 0 ]; then
  pass "unreadable transcript directory case skipped (running as root)"
else
  expect_code 4 "$code" "unreadable evidence exits 4"
  assert_contains "$out" "verdict: unverifiable" "unreadable evidence is unverifiable"
  pass "unreadable evidence fails loudly"
fi

wt=$(meta find-failure opus spawned_at=1)
write_transcript "$wt" s1 claude-opus-5
fakebin=$(fm_fakebin "$TMP_ROOT/find-failure")
cat > "$fakebin/find" <<'SH'
#!/usr/bin/env bash
echo "synthetic find failure" >&2
exit 7
SH
chmod +x "$fakebin/find"
out=$(run_verify_with_path "$fakebin" find-failure); code=$?
expect_code 4 "$code" "transcript enumeration failure exits 4"
assert_contains "$out" "verdict: unverifiable" "find failure is unverifiable"
assert_contains "$out" "could not be enumerated" "find failure retains its cause"
pass "transcript enumeration failure fails loudly"

wt=$(meta stat-failure opus spawned_at=1)
write_transcript "$wt" s1 claude-opus-5
fakebin=$(fm_fakebin "$TMP_ROOT/stat-failure")
cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
exit 9
SH
chmod +x "$fakebin/stat"
out=$(run_verify_with_path "$fakebin" stat-failure); code=$?
expect_code 4 "$code" "transcript stat failure exits 4"
assert_contains "$out" "verdict: unverifiable" "stat failure is unverifiable"
assert_contains "$out" "modification time could not be read" "stat failure retains its cause"
pass "transcript stat failure fails loudly"

# --- (f) pending and unpinned are distinct no-verdict outcomes --------------

wt=$(meta fresh-worker opus)
dir=$(encoded_dir "$wt")
mkdir -p "$dir"
printf '{"type":"user","message":{"role":"user"}}\n' > "$dir/s1.jsonl"
out=$(run_verify fresh-worker); code=$?
expect_code 0 "$code" "a worker with no turn yet does not alarm"
assert_contains "$out" "verdict: pending" "no model-attributed turn yet is pending"
assert_not_contains "$out" "verdict: match" "pending never reads as a verified match"
pass "a worker that has not taken a turn is pending, not verified"
out=$(run_verify fresh-worker --terminal); code=$?
expect_code 4 "$code" "terminal verification rejects pending evidence"
assert_contains "$out" "verdict: pending" "terminal rejection preserves the pending verdict"
pass "terminal verification rejects pending as no verdict"

# Terminal mode decides whether cleanup may discard this task's evidence. It
# blocks only where a verdict was actually possible: refusing whenever one is
# absent would make non-forced cleanup impossible for every harness that can
# never produce one, which is a fleet-wide regression rather than the boundary
# the refusal exists to draw. The verdict is surfaced either way.
out=$(run_verify other-harness --terminal); code=$?
expect_code 0 "$code" "a harness with no evidence adapter must not block cleanup"
assert_contains "$out" "verdict: unverifiable" "the blocked-cleanup exemption still surfaces the verdict"
pass "terminal verification does not block cleanup for a harness that can never produce a verdict"

wt=$(meta terminal-no-model opus)
sed -i.bak '/^model=/d' "$HOME_DIR/state/terminal-no-model.meta"
rm -f "$HOME_DIR/state/terminal-no-model.meta.bak"
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify terminal-no-model --terminal); code=$?
expect_code 0 "$code" "an unpinned-by-omission dispatch must not block cleanup"
assert_contains "$out" "verdict: unverifiable" "a missing model record still reports unverifiable"
pass "terminal verification does not block cleanup when no model was ever pinned"

out=$(run_verify downgrade --terminal); code=$?
expect_code 3 "$code" "a mismatch always blocks cleanup"
assert_contains "$out" "verdict: mismatch" "the blocking verdict is surfaced"
pass "terminal verification always blocks cleanup on a mismatch"

# `<synthetic>` is a runtime placeholder for messages no model served. It must
# neither manufacture a mismatch nor stand in as evidence of a match.
wt=$(meta synthetic-only opus)
write_transcript "$wt" s1 '<synthetic>'
out=$(run_verify synthetic-only); code=$?
expect_code 0 "$code" "synthetic-only evidence does not alarm"
assert_contains "$out" "verdict: pending" "a synthetic placeholder is not a model"
pass "synthetic placeholder is not mistaken for a model"

wt=$(meta mixed-placeholder opus)
write_transcript "$wt" s1 '<synthetic>' claude-opus-5
out=$(run_verify mixed-placeholder); code=$?
expect_code 0 "$code" "synthetic alongside a real model does not alarm"
assert_contains "$out" "verdict: match" "the real model is compared and the placeholder ignored"
assert_not_contains "$out" "synthetic" "the placeholder is not reported as an actual model"
pass "synthetic placeholder never manufactures a mismatch"

# Nothing was promised, so there is no record for the runtime to contradict.
wt=$(meta unpinned-dispatch default)
write_transcript "$wt" s1 claude-sonnet-5
out=$(run_verify unpinned-dispatch); code=$?
expect_code 0 "$code" "an unpinned dispatch does not alarm"
assert_contains "$out" "verdict: unpinned" "no pinned model means no promise to check"
assert_not_contains "$out" "verdict: match" "unpinned never claims a verified match"
pass "unpinned dispatch is reported as unpinned, not verified"
out=$(run_verify unpinned-dispatch --terminal); code=$?
expect_code 0 "$code" "terminal verification allows an unpinned dispatch"
assert_contains "$out" "verdict: unpinned" "terminal unpinned output stays explicit"
pass "terminal verification allows unpinned without calling it verified"

wt=$(meta malformed-spawn-time opus spawned_at=not-an-epoch)
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify malformed-spawn-time); code=$?
expect_code 4 "$code" "malformed dispatch timestamp exits 4"
assert_contains "$out" "verdict: unverifiable" "a malformed dispatch timestamp is not treated as legacy"
assert_not_contains "$out" "verdict: match" "malformed dispatch metadata cannot manufacture a match"
pass "malformed dispatch timestamps fail loudly"

# --- (g) spawned_at binds evidence to this dispatch -------------------------
#
# A worktree from a reusable pool can still carry the transcripts of a previous
# occupant. The dispatch timestamp is what tells the two apart.

wt=$(meta reused-slot opus spawned_at="$(( $(date +%s) - 2 ))")
write_transcript "$wt" old claude-opus-4-8
touch -t 200001010000 "$(encoded_dir "$wt")/old.jsonl"
write_transcript "$wt" new claude-opus-5
out=$(run_verify reused-slot); code=$?
expect_code 0 "$code" "a bound scan ignores a previous occupant"
assert_contains "$out" "verdict: match" "only this dispatch's evidence is compared"
assert_not_contains "$out" "claude-opus-4-8" "the previous occupant's model is not attributed to this task"
pass "dispatch timestamp binds evidence to this dispatch"

# A bound scan still catches a real deviation inside its own window.
wt=$(meta reused-slot-bad opus spawned_at="$(( $(date +%s) - 2 ))")
write_transcript "$wt" old claude-opus-5
touch -t 200001010000 "$(encoded_dir "$wt")/old.jsonl"
write_transcript "$wt" new claude-sonnet-5
out=$(run_verify reused-slot-bad); code=$?
expect_code 3 "$code" "a bound scan still detects this dispatch's own downgrade"
assert_contains "$out" "verdict: mismatch" "binding does not blunt detection"
pass "dispatch timestamp does not hide a real downgrade"

wt=$(meta equal-second opus)
write_transcript "$wt" old claude-opus-5
touch -t 200001010000 "$(encoded_dir "$wt")/old.jsonl"
printf 'spawned_at=%s\n' "$(test_mtime "$(encoded_dir "$wt")/old.jsonl")" \
  >> "$HOME_DIR/state/equal-second.meta"
out=$(run_verify equal-second); code=$?
expect_code 4 "$code" "equal-second evidence without an identity watermark exits 4"
assert_contains "$out" "verdict: unverifiable" "equal-second evidence is not guessed"
assert_not_contains "$out" "verdict: match" "equal-second evidence never reuses a prior match"
pass "equal-second legacy evidence fails loudly instead of matching"

wt=$(meta exact-watermark opus \
  model_evidence_watermark=claude-transcript-v1 model_evidence_before=old.jsonl)
write_transcript "$wt" old claude-opus-5
write_transcript "$wt" new claude-sonnet-5
touch -t 200001010000 "$(encoded_dir "$wt")/old.jsonl" "$(encoded_dir "$wt")/new.jsonl"
printf 'spawned_at=%s\n' "$(test_mtime "$(encoded_dir "$wt")/old.jsonl")" \
  >> "$HOME_DIR/state/exact-watermark.meta"
out=$(run_verify exact-watermark); code=$?
expect_code 3 "$code" "identity watermark catches a same-second current mismatch"
assert_contains "$out" "verdict: mismatch" "the current same-second transcript is compared"
assert_contains "$out" "actual: claude-sonnet-5" "only the current transcript identity is attributed"
assert_not_contains "$out" "claude-opus-5" "the baseline transcript identity is excluded"
pass "identity watermark disambiguates transcripts sharing the spawn second"

wt=$(meta persisted-store opus spawned_at=1 model_evidence_watermark=claude-transcript-v1)
write_transcript "$wt" current claude-sonnet-5
other_cfg="$TMP_ROOT/other-claude"
other_dir="$other_cfg/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$other_dir"
printf '{"type":"assistant","message":{"model":"claude-opus-5"}}\n' > "$other_dir/older-match.jsonl"
out=$(CLAUDE_CONFIG_DIR="$other_cfg" run_verify persisted-store); code=$?
expect_code 3 "$code" "verification remains bound to the persisted evidence store"
assert_contains "$out" "verdict: mismatch" "ambient config cannot replace the dispatch evidence store"
assert_contains "$out" "claude-sonnet-5" "the persisted store supplies the actual model"
assert_not_contains "$out" "actual: claude-opus-5" "an ambient matching transcript cannot manufacture a match"
pass "persisted evidence-store identity survives ambient config changes"

capture_wt="$TMP_ROOT/wt/capture-watermark"
mkdir -p "$capture_wt"
write_transcript "$capture_wt" existing claude-opus-5
out=$(FM_HOME="$HOME_DIR" "$VERIFY" --capture-watermark "$capture_wt" 2>&1); code=$?
expect_code 0 "$code" "watermark capture succeeds"
assert_contains "$out" "model_evidence_watermark=claude-transcript-v1" "watermark format is recorded"
assert_contains "$out" "model_evidence_store=$CFG" "canonical evidence store is recorded"
assert_contains "$out" "model_evidence_before=existing.jsonl" "existing transcript identity is recorded"
pass "spawn-time watermark capture records existing transcript identities"

canonical_root="$TMP_ROOT/canonical-store"
mkdir -p "$canonical_root/real/child" "$canonical_root/real/cfg"
ln -s "$canonical_root/real/child" "$canonical_root/link"
out=$(CLAUDE_CONFIG_DIR="$canonical_root/link/../cfg" \
  FM_HOME="$HOME_DIR" "$VERIFY" --capture-watermark "$capture_wt" 2>&1); code=$?
expect_code 0 "$code" "symlink-plus-parent evidence store canonicalizes"
assert_contains "$out" "model_evidence_store=$canonical_root/real/cfg" \
  "canonicalization did not resolve the symlink before its parent component"
assert_not_contains "$out" "model_evidence_store=$canonical_root/cfg" \
  "canonicalization stripped the parent component before resolving the symlink"
pass "evidence-store canonicalization follows filesystem resolution order"

newline_root="$TMP_ROOT/newline-store"
newline_target="$newline_root/physical"$'\n'"store"
mkdir -p "$newline_target"
ln -s "$newline_target" "$newline_root-link"
wt=$(meta newline-store opus)
sed -i.bak '/^model_evidence_store=/d' "$HOME_DIR/state/newline-store.meta"
rm -f "$HOME_DIR/state/newline-store.meta.bak"
out=$(CLAUDE_CONFIG_DIR="$newline_root-link" run_verify newline-store); code=$?
expect_code 4 "$code" "newline-bearing physical evidence store exits 4"
assert_contains "$out" "verdict: unarmed" \
  "newline-bearing physical evidence store did not fail loudly"
assert_contains "$out" "names no model-evidence store" \
  "an unrecorded ambient store did not become authoritative"
assert_not_contains "$out" "verdict: match" \
  "newline-bearing physical evidence store manufactured a match"
pass "newline-bearing physical evidence stores never resolve against ambient state"

# Without a timestamp, disagreeing evidence cannot be attributed. Guessing which
# half belongs to this task would be exactly the silent pass to avoid.
wt=$(meta unbound-ambiguous opus)
sed -i.bak '/^model_evidence_store=/d' "$HOME_DIR/state/unbound-ambiguous.meta"
rm -f "$HOME_DIR/state/unbound-ambiguous.meta.bak"
write_transcript "$wt" a claude-opus-5
write_transcript "$wt" b claude-opus-4-8
out=$(run_verify unbound-ambiguous); code=$?
expect_code 4 "$code" "unattributable evidence exits 4"
assert_contains "$out" "verdict: unarmed" "disagreeing unbound evidence produces no verdict"
assert_contains "$out" "names no model-evidence store" \
  "unbound evidence did not bypass the missing recorded store"
assert_not_contains "$out" "actual: claude-opus" \
  "ambient transcripts were attributed to a dispatch that recorded no store"
pass "unbound evidence without a recorded store fails loudly"

# Unanimous ambient evidence is not attributable without a persisted store.
wt=$(meta unbound-agreed opus)
sed -i.bak '/^model_evidence_store=/d' "$HOME_DIR/state/unbound-agreed.meta"
rm -f "$HOME_DIR/state/unbound-agreed.meta.bak"
write_transcript "$wt" a claude-opus-5
write_transcript "$wt" b claude-opus-5
out=$(run_verify unbound-agreed); code=$?
expect_code 4 "$code" "unanimous ambient evidence without a recorded store exits 4"
assert_contains "$out" "verdict: unarmed" \
  "unanimous ambient evidence without a recorded store produced a verdict anyway"
assert_not_contains "$out" "verdict: match" \
  "unanimous ambient evidence did not manufacture an authoritative match"
assert_contains "$out" "actual: -" \
  "ambient transcripts were read for a dispatch that recorded no store"
pass "unanimous ambient evidence requires a recorded store identity"

# --- secondmate: the worker runs in its own home, not a worktree ------------

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME"
fm_write_secondmate_meta "$HOME_DIR/state/sm.meta" "$SM_HOME" "firstmate:fm-sm" alpha claude
printf 'model=opus\n' >> "$HOME_DIR/state/sm.meta"
printf 'model_evidence_store=%s\n' "$CFG" >> "$HOME_DIR/state/sm.meta"
write_transcript "$SM_HOME" s1 claude-opus-5
out=$(run_verify sm); code=$?
expect_code 0 "$code" "secondmate evidence resolves from its home"
assert_contains "$out" "verdict: match" "a secondmate's evidence lives under its own home"
pass "secondmate evidence is read from its home"

# --- (h) --all reports every task and exits on the worst verdict ------------

out=$(run_verify --all); code=$?
expect_code 4 "$code" "--all exits on the worst verdict present"
assert_contains "$out" "alias-match" "--all reports every recorded task"
assert_contains "$out" "verdict: mismatch" "--all surfaces mismatches"
assert_contains "$out" "verdict: unverifiable" "--all surfaces unverifiable tasks"
pass "--all reports every task and exits on the worst verdict"

# A home whose every task is fine exits 0 - no behavior change for correctly
# routed work.
CLEAN_HOME="$TMP_ROOT/clean"
mkdir -p "$CLEAN_HOME/state"
clean_wt="$TMP_ROOT/wt/clean-task"
mkdir -p "$clean_wt"
fm_write_meta "$CLEAN_HOME/state/clean-task.meta" \
  "worktree=$clean_wt" "harness=claude" "kind=ship" "model=opus" \
  "model_evidence_store=$CFG" "spawned_at=1"
write_transcript "$clean_wt" s1 claude-opus-5
out=$(FM_HOME="$CLEAN_HOME" FM_STATE_OVERRIDE="$CLEAN_HOME/state" "$VERIFY" --all 2>&1); code=$?
expect_code 0 "$code" "a correctly routed fleet exits 0"
assert_contains "$out" "verdict: match" "a correctly routed fleet reports match"
pass "a correctly routed fleet exits 0"

# --- structured output -------------------------------------------------------

out=$(run_verify downgrade --json); code=$?
expect_code 3 "$code" "--json preserves the verdict exit code"
verdict=$(printf '%s' "$out" | jq -r '.verdict')
[ "$verdict" = mismatch ] || fail "--json verdict: expected mismatch, got $verdict"
actual=$(printf '%s' "$out" | jq -r '.actual | join(",")')
[ "$actual" = claude-sonnet-5 ] || fail "--json actual: expected claude-sonnet-5, got $actual"
recorded=$(printf '%s' "$out" | jq -r '.recorded')
[ "$recorded" = opus ] || fail "--json recorded: expected opus, got $recorded"
pass "--json carries verdict, recorded, and actual"

out=$(run_verify --all --json); code=$?
expect_code 4 "$code" "--all --json exits on the worst verdict"
n=$(printf '%s' "$out" | jq -r 'length')
[ "$n" -gt 5 ] || fail "--all --json: expected a row per task, got $n"
printf '%s' "$out" | jq -e 'all(.[]; has("verdict") and has("actual"))' >/dev/null \
  || fail "--all --json: every row must carry a verdict and actual list"
pass "--all --json emits one structured row per task"

# --- usage -------------------------------------------------------------------

out=$(run_verify); code=$?
expect_code 2 "$code" "no arguments is a usage error"
out=$(run_verify a b); code=$?
expect_code 2 "$code" "two task ids is a usage error"
out=$(run_verify --all extra); code=$?
expect_code 2 "$code" "--all with a task id is a usage error"
pass "usage errors exit 2"

printf '\nall fm-model-verify tests passed\n'
