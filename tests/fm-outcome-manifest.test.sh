#!/usr/bin/env bash
# Behavior tests for the durable fleet data contracts: the completion manifest,
# the work-item reference store, the normalized PR observation, and the durable
# history projection they feed.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$ROOT/bin/fm-outcome-manifest.sh"
WORKITEM="$ROOT/bin/fm-work-item.sh"
PRSTATUS="$ROOT/bin/fm-pr-status.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-outcome-manifest)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

fm() {  # <home> <cmd...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

seed_ship_task() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf '# brief\n' > "$home/data/$id/brief.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/projects/$id-worktree" \
    "project=$home/projects/alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-$id" \
    "model=opus" \
    "effort=xhigh"
}

# --- manifest composition ---------------------------------------------------

test_manifest_composition() {
  local home id out
  home=$(make_home compose)
  id=ship-a
  seed_ship_task "$home" "$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Durable outcome manifest (mobile) https://github.com/acme/widget/pull/9 (repo: widget) (kind: ship) (since 2026-07-04)
EOF
  printf 'working: started\ndone: PR https://github.com/acme/widget/pull/9 checks green\n' \
    > "$home/state/$id.status"
  printf 'pr=https://github.com/acme/widget/pull/9\n' >> "$home/state/$id.meta"
  printf 'pr_head=0123456789abcdef0123456789abcdef01234567\n' >> "$home/state/$id.meta"

  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id") || fail "manifest show failed"

  [ "$(printf '%s' "$out" | jq -r '.schema')" = fm-outcome-manifest.v1 ] \
    || fail "manifest schema is not fm-outcome-manifest.v1"
  [ "$(printf '%s' "$out" | jq -r '.task_id')" = "$id" ] || fail "manifest task id is wrong"
  [ "$(printf '%s' "$out" | jq -r '.title')" = "Durable outcome manifest (mobile)" ] \
    || fail "manifest title was not taken from the backlog row: $(printf '%s' "$out" | jq -r '.title')"
  [ "$(printf '%s' "$out" | jq -r '.kind')" = ship ] || fail "manifest kind is wrong"
  [ "$(printf '%s' "$out" | jq -r '.mode')" = no-mistakes ] || fail "manifest mode is wrong"
  [ "$(printf '%s' "$out" | jq -r '.harness')" = claude ] || fail "manifest harness is wrong"
  [ "$(printf '%s' "$out" | jq -r '.model')" = opus ] || fail "manifest model is wrong"
  [ "$(printf '%s' "$out" | jq -r '.effort')" = xhigh ] || fail "manifest effort is wrong"
  [ "$(printf '%s' "$out" | jq -r '.outcome.state')" = "done" ] \
    || fail "manifest outcome state was not read from the terminal status event"
  [ "$(printf '%s' "$out" | jq -r '.outcome.source')" = status_event ] \
    || fail "manifest outcome source is wrong"
  [ "$(printf '%s' "$out" | jq -r '.outcome.forced')" = false ] \
    || fail "an ordinary teardown must not record a forced outcome"
  [ "$(printf '%s' "$out" | jq -r '.pr.number')" = 9 ] || fail "manifest PR number is wrong"
  [ "$(printf '%s' "$out" | jq -r '.pr.provider')" = github ] || fail "manifest PR provider is wrong"
  [ "$(printf '%s' "$out" | jq -r '.pr.head')" = 0123456789abcdef0123456789abcdef01234567 ] \
    || fail "manifest PR head is wrong"
  [ "$(printf '%s' "$out" | jq -r '.pr.status.state')" = unknown ] \
    || fail "an unrefreshed PR must report state unknown"

  # #13 attributes usage after teardown from these retained references alone.
  [ "$(printf '%s' "$out" | jq -r '.attribution.backend')" = tmux ] || fail "attribution backend is wrong"
  [ "$(printf '%s' "$out" | jq -r '.attribution.endpoint.target')" = "firstmate:fm-$id" ] \
    || fail "attribution endpoint target is wrong"
  [ "$(printf '%s' "$out" | jq -r '.attribution.endpoint.task_id')" = "$id" ] \
    || fail "attribution endpoint task id is wrong"
  [ "$(printf '%s' "$out" | jq -r '.attribution.worktree')" = "$home/projects/$id-worktree" ] \
    || fail "attribution worktree is wrong"
  [ "$(printf '%s' "$out" | jq -r '.attribution.task_tmp')" = "/tmp/fm-$id" ] \
    || fail "attribution task temp root is wrong"

  # Timestamps name their own provenance rather than implying a precision the
  # records do not carry.
  [ "$(printf '%s' "$out" | jq -r '.timestamp_sources.created')" = brief_mtime ] \
    || fail "created should come from the brief mtime when a brief exists"
  [ "$(printf '%s' "$out" | jq -r '.timestamp_sources.started')" = meta_mtime ] \
    || fail "started should come from the task metadata mtime"
  [ "$(printf '%s' "$out" | jq -r '.timestamp_sources.completed')" = manifest_write ] \
    || fail "completed should default to the write time"
  printf '%s' "$out" | jq -e '.timestamps | to_entries | all(.value | test("^[0-9]{4}-.*Z$"))' >/dev/null \
    || fail "every timestamp must be an ISO-8601 UTC stamp"

  # A missing optional provider is a first-class answer, not an error.
  [ "$(printf '%s' "$out" | jq -r '.gbrain.status')" = absent ] \
    || fail "an absent GBrain provider must report status absent"
  printf '%s' "$out" | jq -e '.gbrain.receipt == null' >/dev/null \
    || fail "an absent GBrain provider must leave the receipt null"

  [ "$(stat_mode "$home/data/$id/outcome.json")" = 600 ] \
    || fail "the manifest must be published privately"
  pass "the manifest composes dispatch, outcome, PR, attribution, and provenance from live records"
}

stat_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

test_manifest_gbrain_and_overrides() {
  local home id out
  home=$(make_home gbrain)
  id=ship-b
  seed_ship_task "$home" "$id"
  printf 'status=captured\nreceipt=gb_01HTEST\nobserved_at=2026-07-04T12:00:00Z\ndetail=captured 3 artifacts\n' \
    > "$home/state/$id.gbrain"

  fm "$home" "$MANIFEST" write "$id" --forced --completed-at 2026-07-05T09:30:00Z >/dev/null \
    || fail "forced manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id")
  [ "$(printf '%s' "$out" | jq -r '.gbrain.status')" = captured ] || fail "GBrain status was not carried"
  [ "$(printf '%s' "$out" | jq -r '.gbrain.receipt')" = gb_01HTEST ] || fail "GBrain receipt was not carried"
  [ "$(printf '%s' "$out" | jq -r '.outcome.state')" = discarded ] \
    || fail "a forced teardown with no terminal event must record a discarded outcome"
  [ "$(printf '%s' "$out" | jq -r '.outcome.forced')" = true ] || fail "forced flag was not recorded"
  [ "$(printf '%s' "$out" | jq -r '.timestamps.completed')" = 2026-07-05T09:30:00Z ] \
    || fail "--completed-at was not honored"
  [ "$(printf '%s' "$out" | jq -r '.timestamp_sources.completed')" = explicit ] \
    || fail "an explicit completion stamp must name its own source"

  # A garbage status from the optional provider degrades to unknown rather than
  # being published verbatim.
  printf 'status=; rm -rf /\nreceipt=not a token\n' > "$home/state/$id.gbrain"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed on a malformed provider record"
  out=$(fm "$home" "$MANIFEST" show "$id")
  [ "$(printf '%s' "$out" | jq -r '.gbrain.status')" = unknown ] \
    || fail "an unrecognized provider status must degrade to unknown"
  printf '%s' "$out" | jq -e '.gbrain.receipt == null' >/dev/null \
    || fail "a receipt with unexpected characters must be dropped"
  pass "the manifest carries an optional provider receipt and refuses to publish its malformed values"
}

test_design_manifest_is_valid() {
  local home id out
  home=$(make_home design-kind)
  id=design-a
  seed_ship_task "$home" "$id"
  printf '%s\n' 'kind=design' >> "$home/state/$id.meta"
  printf 'done: ADR ready\n' > "$home/state/$id.status"

  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "design manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id") || fail "design manifest validation failed"
  printf '%s' "$out" | jq -e '.kind == "design" and .outcome.state == "done"' >/dev/null \
    || fail "design kind did not survive durable manifest validation"
  pass "design is a valid durable outcome manifest kind"
}

# The mattpocock plugin a design interview reads auto-updates, so the release
# that informed one design result need not be the one that informs the next.
# Spawn resolves it at dispatch and records it in task metadata; the manifest is
# what carries it past cleanup, which is the only reason it is still readable.
test_design_manifest_carries_the_plugin_release() {
  local home id out
  home=$(make_home design-provenance)
  id=design-p
  seed_ship_task "$home" "$id"
  {
    printf 'kind=design\n'
    printf 'design_skills_plugin=mattpocock-skills@mattpocock\n'
    printf 'design_skills_version=1.4.2\n'
    printf 'design_skills_updated=2026-08-26T09:15:00Z\n'
  } >> "$home/state/$id.meta"
  printf 'done: ADR ready\n' > "$home/state/$id.status"

  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "design manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id") || fail "design manifest validation failed"
  printf '%s' "$out" | jq -e '.design_skills
    == {plugin:"mattpocock-skills@mattpocock",version:"1.4.2",last_updated:"2026-08-26T09:15:00Z"}' \
    >/dev/null || fail "the manifest lost the plugin release the design task was dispatched against"

  # The whole point is surviving cleanup, so it must also come back through the
  # durable history projection, which revalidates every record it returns.
  out=$(fm "$home" "$MANIFEST" list)
  printf '%s' "$out" | jq -e --arg id "$id" \
    '.records | any(.task_id == $id and .design_skills.version == "1.4.2")' >/dev/null \
    || fail "the plugin release did not survive into durable history: $out"
  pass "a design task's manifest records the plugin release it was dispatched against"
}

# Recording a guess would be worse than recording nothing: a reader could not
# tell an inferred version from an observed one. So a task that never resolved
# the plugin - every non-design task, and any design task dispatched before
# spawn recorded it - carries no key at all, not an empty string.
test_manifest_omits_an_unresolved_plugin_release() {
  local home id out
  home=$(make_home design-unrecorded)

  id=ship-noplugin
  seed_ship_task "$home" "$id"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "ship manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id") || fail "ship manifest validation failed"
  printf '%s' "$out" | jq -e 'has("design_skills") | not' >/dev/null \
    || fail "a non-design task paid for the design plugin record"

  # A design task whose metadata carries only part of the record is still a task
  # whose inputs are unknown, so it records nothing rather than half an answer.
  id=design-partial
  seed_ship_task "$home" "$id"
  {
    printf 'kind=design\n'
    printf 'design_skills_plugin=mattpocock-skills@mattpocock\n'
  } >> "$home/state/$id.meta"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "partial design manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id") || fail "partial design manifest validation failed"
  printf '%s' "$out" | jq -e 'has("design_skills") | not' >/dev/null \
    || fail "an incomplete plugin record was published instead of being left out"
  pass "a task that never resolved the plugin records no release rather than a guess"
}

# The manifest reader revalidates every record on every history read, so a
# manifest published before this key existed must stay valid or the upgrade
# would drop real durable history.
test_manifest_without_design_skills_stays_valid() {
  local home id path legacy out
  home=$(make_home legacy-design-skills)
  id=design-legacy
  seed_ship_task "$home" "$id"
  printf 'kind=design\n' >> "$home/state/$id.meta"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed"
  path="$home/data/$id/outcome.json"
  legacy=$(jq -c 'del(.design_skills)' "$path") || fail "legacy manifest fixture failed"
  printf '%s\n' "$legacy" > "$path"

  fm "$home" "$MANIFEST" validate "$id" >/dev/null \
    || fail "a manifest written before the design plugin record was invalidated by the upgrade"
  out=$(fm "$home" "$MANIFEST" list)
  printf '%s' "$out" | jq -e --arg id "$id" '
    (.records | any(.task_id == $id)) and (.malformed | any(.id == $id) | not)' >/dev/null \
    || fail "pre-upgrade durable history was reclassified as malformed: $out"
  pass "a manifest written before the design plugin record stays valid in durable history"
}

test_secondmate_manifest_title_is_null() {
  local home out
  home=$(make_home secondmate-title)
  fm_write_secondmate_meta "$home/state/design.meta" "$home/secondmate-design"
  fm "$home" "$MANIFEST" write design >/dev/null || fail "secondmate manifest write failed"
  out=$(fm "$home" "$MANIFEST" show design)
  printf '%s' "$out" | jq -e '.kind == "secondmate" and .title == null and .outcome.state == "retired"' >/dev/null \
    || fail "a secondmate manifest synthesized a backlog title"
  fm "$home" "$MANIFEST" validate design >/dev/null || fail "secondmate manifest did not validate"
  out=$(fm "$home" "$MANIFEST" list)
  printf '%s' "$out" | jq -e '.records[0]
    | .task_id == "design" and .title == null and .gbrain.status == "absent"
      and .gbrain.receipt == null and .gbrain.observed_at == null and .gbrain.detail == null' >/dev/null \
    || fail "a secondmate with an absent optional provider did not remain in durable history"
  pass "secondmate manifests retain nullable title and provider fields in durable history"
}

# The usage session map was added to the attribution object after manifests were
# already on disk, and fm_outcome_history_json revalidates every one of them on
# every read. A manifest published before that contract existed must therefore
# stay valid, or the upgrade would silently reclassify real durable history as
# invalid and drop it out of the dashboard.
test_manifest_without_sessions_stays_valid() {
  local home id path legacy out
  home=$(make_home legacy-sessions)
  id=ship-legacy
  seed_ship_task "$home" "$id"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed"
  path="$home/data/$id/outcome.json"

  # Exactly the shape an older firstmate wrote: the attribution object with no
  # sessions key at all, not an empty one.
  legacy=$(jq -c 'del(.attribution.sessions)' "$path") || fail "legacy manifest fixture failed"
  printf '%s\n' "$legacy" > "$path"
  printf '%s' "$legacy" | jq -e '.attribution | has("sessions") | not' >/dev/null \
    || fail "the legacy fixture still carries a sessions key"

  fm "$home" "$MANIFEST" validate "$id" >/dev/null \
    || fail "a manifest written before the usage session map was invalidated by the upgrade"
  fm "$home" "$MANIFEST" show "$id" >/dev/null \
    || fail "a manifest written before the usage session map could not be read back"
  out=$(fm "$home" "$MANIFEST" list)
  printf '%s' "$out" | jq -e --arg id "$id" '
    (.records | any(.task_id == $id)) and (.malformed | any(.id == $id) | not)' >/dev/null \
    || fail "pre-upgrade durable history was reclassified as malformed: $out"
  pass "a manifest written before the usage session map stays valid in durable history"
}

test_manifest_requires_metadata_and_allowlist() {
  local home id path valid history rc out
  home=$(make_home refuse)
  rc=0
  fm "$home" "$MANIFEST" write ghost >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "writing a manifest for a task with no metadata must fail"

  # The allowlist is the enforcement point, so prove it refuses an extra field
  # through the same publication helper the writer uses.
  out=$(cd "$ROOT" && bash -c '
    . bin/fm-outcome-lib.sh
    doc=$(jq -n "{schema:\"fm-outcome-manifest.v1\",task_id:\"x\",smuggled_token:\"sk-live-1\"}")
    if fm_outcome_manifest_keys_valid "$doc" 2>/dev/null; then echo accepted; else echo refused; fi
  ')
  [ "$out" = refused ] || fail "the manifest allowlist accepted an undeclared field"

  id=shape-check
  seed_ship_task "$home" "$id"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "valid manifest setup failed"
  path="$home/data/$id/outcome.json"
  valid=$(<"$path")
  printf '%s' "$valid" | jq -c '{schema,task_id,work_items,pr}' > "$path"
  rc=0
  fm "$home" "$MANIFEST" show "$id" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a manifest missing required fields was emitted"
  history=$(fm "$home" "$MANIFEST" list)
  printf '%s' "$history" | jq -e --arg id "$id" '
    .records == [] and (.malformed | any(.id == $id and .reason == "invalid_values"))' >/dev/null \
    || fail "an incomplete manifest was not disclosed as malformed"

  printf '%s\n%s\n' "$valid" "$valid" > "$path"
  rc=0
  fm "$home" "$MANIFEST" show "$id" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a doubled manifest document was emitted"
  history=$(fm "$home" "$MANIFEST" list)
  printf '%s' "$history" | jq -e --arg id "$id" '
    .records == [] and (.malformed | any(.id == $id and .reason == "unreadable_or_wrong_schema"))' >/dev/null \
    || fail "a doubled manifest was not disclosed as malformed"
  pass "manifest publication and reads require the complete single-root contract"
}

# --- work-item references ---------------------------------------------------

test_work_items_round_trip() {
  local home id out
  home=$(make_home workitems)
  id=ship-c
  seed_ship_task "$home" "$id"

  fm "$home" "$WORKITEM" add "$id" https://github.com/acme/widget/issues/18 >/dev/null \
    || fail "adding a GitHub issue reference failed"
  fm "$home" "$WORKITEM" add "$id" https://gitlab.example.com/group/sub/proj/-/issues/7 \
    --origin pr-linked --title 'Nested group issue' --state open \
    --observed-at 2026-07-04T00:00:00Z --source glab >/dev/null \
    || fail "adding a self-hosted GitLab reference failed"
  fm "$home" "$WORKITEM" add "$id" https://git.internal.example/team/tool/issues/4 \
    --forge forgejo >/dev/null || fail "adding a reference with an explicit forge failed"
  fm "$home" "$WORKITEM" add "$id" https://tracker.example.net/board/card-12 >/dev/null \
    || fail "adding a reference on an unrecognized host failed"

  out=$(fm "$home" "$WORKITEM" list "$id")
  [ "$(printf '%s' "$out" | jq -r '.schema')" = fm-work-items.v1 ] || fail "work-item schema is wrong"
  [ "$(printf '%s' "$out" | jq '.references | length')" = 4 ] \
    || fail "expected four references, got $(printf '%s' "$out" | jq '.references | length')"

  printf '%s' "$out" | jq -e '.references[0]
    | .forge == "github" and .host == "github.com" and .owner == "acme"
      and .repo == "widget" and .number == 18 and .kind == "issue"
      and .origin == "intake" and .enrichment.title == null' >/dev/null \
    || fail "the GitHub reference did not round-trip with null enrichment"
  printf '%s' "$out" | jq -e '.references[1]
    | .forge == "gitlab" and .host == "gitlab.example.com"
      and .path == "group/sub/proj" and .owner == "group/sub" and .repo == "proj"
      and .number == 7 and .origin == "pr-linked"
      and .enrichment.title == "Nested group issue" and .enrichment.state == "open"' >/dev/null \
    || fail "the nested self-hosted GitLab reference did not round-trip"
  printf '%s' "$out" | jq -e '.references[2] | .forge == "forgejo" and .number == 4' >/dev/null \
    || fail "an explicit forge override was not honored"
  printf '%s' "$out" | jq -e '.references[3]
    | .forge == "unknown" and .number == null and .kind == "unknown"' >/dev/null \
    || fail "an unrecognized host must store forge unknown rather than being rejected or guessed"

  # Upsert by canonical URL: a resolver may run repeatedly without duplicating.
  fm "$home" "$WORKITEM" add "$id" https://github.com/acme/widget/issues/18 \
    --title 'Now enriched' --state closed >/dev/null || fail "re-adding a known reference failed"
  out=$(fm "$home" "$WORKITEM" list "$id")
  [ "$(printf '%s' "$out" | jq '.references | length')" = 4 ] \
    || fail "re-adding a known reference duplicated it"
  printf '%s' "$out" | jq -e '.references[0].enrichment
    | .title == "Now enriched" and .state == "closed"' >/dev/null \
    || fail "re-adding a known reference did not update its enrichment in place"

  # A task with no store is indistinguishable from a task with an empty one.
  out=$(fm "$home" "$WORKITEM" list never-stored)
  printf '%s' "$out" | jq -e '.schema == "fm-work-items.v1" and (.references | length) == 0' >/dev/null \
    || fail "a task with no work-item store must still read as a valid empty document"
  pass "work-item references round-trip across forges and hosts, upsert by URL, and stay renderable unenriched"
}

test_work_item_rejects_unusable_urls() {
  local home url rc
  home=$(make_home workitems-bad)
  for url in 'not-a-url' 'ftp://example.com/x/issues/1' \
      'https://example.com/../../etc/passwd' 'https://exa mple.com/a/b/issues/1' \
      'https://example.com/a/b/issues/0'; do
    rc=0
    fm "$home" "$WORKITEM" parse "$url" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "an unusable work-item URL was accepted: $url"
  done
  pass "the work-item store refuses relative, non-http, traversing, and malformed URLs"
}

test_work_item_mutations_refuse_invalid_store() {
  local home id before after valid rc command
  home=$(make_home workitems-invalid-store)
  id=ship-invalid
  mkdir -p "$home/data/$id"
  printf '{"schema":"fm-work-items.v0","task_id":"%s","references":[{"legacy":true}]}\n' "$id" \
    > "$home/data/$id/work-items.json"
  before=$(<"$home/data/$id/work-items.json")

  for command in add remove clear; do
    rc=0
    case "$command" in
      add) fm "$home" "$WORKITEM" add "$id" https://github.com/acme/widget/issues/19 >/dev/null 2>&1 || rc=$? ;;
      remove) fm "$home" "$WORKITEM" remove "$id" https://github.com/acme/widget/issues/19 >/dev/null 2>&1 || rc=$? ;;
      clear) fm "$home" "$WORKITEM" clear "$id" >/dev/null 2>&1 || rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "$command overwrote a present invalid work-item store"
    after=$(<"$home/data/$id/work-items.json")
    [ "$after" = "$before" ] || fail "$command changed a present invalid work-item store"
  done

  fm "$home" "$WORKITEM" list "$id" \
    | jq -e '.schema == "fm-work-items.v1" and .references == []' >/dev/null \
    || fail "the read-only projection did not degrade an invalid work-item store to empty"

  valid=$(jq -cn --arg id "$id" '{schema:"fm-work-items.v1",task_id:$id,references:[]}')
  printf '%s\n%s\n' "$valid" "$valid" > "$home/data/$id/work-items.json"
  before=$(<"$home/data/$id/work-items.json")
  for command in add remove clear; do
    rc=0
    case "$command" in
      add) fm "$home" "$WORKITEM" add "$id" https://github.com/acme/widget/issues/19 >/dev/null 2>&1 || rc=$? ;;
      remove) fm "$home" "$WORKITEM" remove "$id" https://github.com/acme/widget/issues/19 >/dev/null 2>&1 || rc=$? ;;
      clear) fm "$home" "$WORKITEM" clear "$id" >/dev/null 2>&1 || rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "$command accepted a doubled work-item store"
    after=$(<"$home/data/$id/work-items.json")
    [ "$after" = "$before" ] || fail "$command changed a doubled work-item store"
  done
  fm "$home" "$WORKITEM" list "$id" \
    | jq -e '.schema == "fm-work-items.v1" and .references == []' >/dev/null \
    || fail "the read-only projection did not degrade a doubled work-item store to empty"
  pass "work-item mutations preserve invalid single- and multi-root durable stores"
}

# --- normalized PR observation ----------------------------------------------

test_pr_status_normalization() {
  local out
  out=$(cd "$ROOT" && bash -c '
    . bin/fm-outcome-lib.sh
    printf "%s %s %s %s\n" \
      "$(fm_outcome_pr_state_normalize OPEN false true)" \
      "$(fm_outcome_pr_state_normalize open true false)" \
      "$(fm_outcome_pr_state_normalize CLOSED false false)" \
      "$(fm_outcome_pr_state_normalize weird false false)"
    printf "%s %s %s\n" \
      "$(fm_outcome_pr_review_normalize CHANGES_REQUESTED)" \
      "$(fm_outcome_pr_review_normalize "")" \
      "$(fm_outcome_pr_review_normalize wat)"
    printf "%s %s %s %s\n" \
      "$(fm_outcome_pr_checks_normalize success)" \
      "$(fm_outcome_pr_checks_normalize timed_out)" \
      "$(fm_outcome_pr_checks_normalize in_progress)" \
      "$(fm_outcome_pr_checks_normalize "")"
    printf "%s %s %s\n" \
      "$(fm_outcome_pr_mergeable_normalize MERGEABLE clean)" \
      "$(fm_outcome_pr_mergeable_normalize MERGEABLE dirty)" \
      "$(fm_outcome_pr_mergeable_normalize "" "")"
    printf "%s %s %s %s %s %s\n" \
      "$(fm_outcome_pr_gitlab_review_normalize false 0 0 0)" \
      "$(fm_outcome_pr_gitlab_review_normalize false 2 2 0)" \
      "$(fm_outcome_pr_gitlab_review_normalize true 2 0 2)" \
      "$(fm_outcome_pr_gitlab_review_normalize true 2 1 1)" \
      "$(fm_outcome_pr_gitlab_review_normalize false 2 0 2)" \
      "$(fm_outcome_pr_gitlab_review_normalize false 2 "" "")"
  ')
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "draft merged closed unknown" ] \
    || fail "PR state normalization is wrong: $(printf '%s\n' "$out" | sed -n 1p)"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "changes_requested none unknown" ] \
    || fail "PR review normalization is wrong: $(printf '%s\n' "$out" | sed -n 2p)"
  [ "$(printf '%s\n' "$out" | sed -n 3p)" = "passing failing pending none" ] \
    || fail "PR check normalization is wrong: $(printf '%s\n' "$out" | sed -n 3p)"
  [ "$(printf '%s\n' "$out" | sed -n 4p)" = "mergeable conflicting unknown" ] \
    || fail "PR mergeability normalization is wrong: $(printf '%s\n' "$out" | sed -n 4p)"
  [ "$(printf '%s\n' "$out" | sed -n 5p)" = "none review_required approved review_required unknown review_required" ] \
    || fail "GitLab review normalization is wrong: $(printf '%s\n' "$out" | sed -n 5p)"
  pass "each forge vocabulary maps onto the normalized state, review, check, and mergeability enumerations"
}

test_pr_status_refresh_and_cache() {
  local home id fakebin out
  home=$(make_home prstatus)
  id=ship-d
  seed_ship_task "$home" "$id"
  printf 'pr=https://github.com/acme/widget/pull/12\n' >> "$home/state/$id.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/prstatus")
  # Only gh answers a --json structured read. gh-axi is given the TOON body it
  # really returns for the same request - it ignores --json and still exits 0 -
  # so a read routed back through the wrapper fails this fixture rather than
  # quietly passing it, and an unmocked read cannot reach the live forge.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *statusCheckRollup*)
    cat <<'JSON'
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
 "reviewDecision":"REVIEW_REQUIRED","headRefOid":"abcdef1234567890abcdef1234567890abcdef12",
 "statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SUCCESS"}]}
JSON
    exit 0 ;;
esac
exit 1
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "pull_request:" "  number: 12" "  state: OPEN"
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"

  PATH="$fakebin:$PATH" fm "$home" "$PRSTATUS" refresh "$id" >/dev/null \
    || fail "PR status refresh failed"
  out=$(fm "$home" "$PRSTATUS" show "$id")
  printf '%s' "$out" | jq -e '.schema == "fm-pr-status.v1" and .number == 12
    and .status.state == "open" and .status.review == "review_required"
    and .status.checks == "passing" and .status.mergeable == "blocked"
    and .status.head == "abcdef1234567890abcdef1234567890abcdef12"' >/dev/null \
    || fail "the cached observation was not normalized as expected: $out"
  [ "$(stat_mode "$home/state/$id.pr-status")" = 600 ] \
    || fail "the PR observation cache must be private"

  # A failing refresh keeps the good reading rather than overwriting it.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh"
  PATH="$fakebin:$PATH" fm "$home" "$PRSTATUS" refresh "$id" >/dev/null 2>&1 \
    && fail "a failed refresh must exit nonzero"
  out=$(fm "$home" "$PRSTATUS" show "$id")
  [ "$(printf '%s' "$out" | jq -r '.status.state')" = open ] \
    || fail "a failed refresh overwrote the previous observation"

  # An unrefreshed task reads as unknown/absent, never as an error.
  out=$(fm "$home" "$PRSTATUS" show never-refreshed)
  printf '%s' "$out" | jq -e '.status.state == "unknown" and .status.source == "absent"' >/dev/null \
    || fail "an unrefreshed task must read as unknown with source absent"

  # The manifest embeds the cached observation without calling a forge.
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id")
  printf '%s' "$out" | jq -e '.pr.status.state == "open" and .pr.status.checks == "passing"' >/dev/null \
    || fail "the manifest did not embed the cached PR observation"

  printf 'pr=https://github.com/acme/widget/pull/13\n' >> "$home/state/$id.meta"
  PATH="$fakebin:$PATH" fm "$home" "$PRSTATUS" refresh "$id" >/dev/null 2>&1 \
    && fail "the replacement PR refresh unexpectedly succeeded"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest rewrite failed"
  out=$(fm "$home" "$MANIFEST" show "$id")
  printf '%s' "$out" | jq -e '.pr.url == "https://github.com/acme/widget/pull/13"
    and .pr.status.state == "unknown" and .pr.status.source == "absent"' >/dev/null \
    || fail "a stale cache was combined with the task replacement PR"
  pass "the PR observation retains same-PR failures and rejects stale cache identity"
}

test_gitlab_approval_state() {
  local home id fakebin out
  home=$(make_home gitlab-approval)
  id=ship-gitlab
  seed_ship_task "$home" "$id"
  printf 'pr=https://gitlab.example.com/group/sub/proj/-/merge_requests/7\n' >> "$home/state/$id.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/gitlab-approval")
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  */approvals) printf '%s\n' '{"approved":true,"approvals_required":2,"approvals_left":0}' ;;
  *) printf '%s\n' '{"state":"opened","draft":false,"detailed_merge_status":"mergeable","approvals_before_merge":9,"sha":"abcdef1234567890abcdef1234567890abcdef12","head_pipeline":{"status":"success"}}' ;;
esac
SH
  chmod +x "$fakebin/glab"

  PATH="$fakebin:$PATH" fm "$home" "$PRSTATUS" refresh "$id" >/dev/null \
    || fail "GitLab PR status refresh failed"
  out=$(fm "$home" "$PRSTATUS" show "$id")
  [ "$(printf '%s' "$out" | jq -r '.status.review')" = approved ] \
    || fail "GitLab's current approved result was not normalized"

  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  */approvals) exit 1 ;;
  *) printf '%s\n' '{"state":"opened","draft":false,"detailed_merge_status":"mergeable","approvals_before_merge":9,"sha":"abcdef1234567890abcdef1234567890abcdef12","head_pipeline":{"status":"success"}}' ;;
esac
SH
  chmod +x "$fakebin/glab"
  PATH="$fakebin:$PATH" fm "$home" "$PRSTATUS" refresh "$id" >/dev/null \
    || fail "GitLab refresh failed when only approval state was unavailable"
  out=$(fm "$home" "$PRSTATUS" show "$id")
  [ "$(printf '%s' "$out" | jq -r '.status.review')" = unknown ] \
    || fail "an unavailable GitLab approval result did not degrade to unknown"
  pass "GitLab review normalization follows current approval state and degrades safely"
}

test_pr_status_fallback_timeout() {
  local home id fakebin started elapsed rc
  home=$(make_home prstatus-timeout)
  id=ship-timeout
  seed_ship_task "$home" "$id"
  printf 'pr=https://github.com/acme/widget/pull/14\n' >> "$home/state/$id.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/prstatus-timeout")
  # gh is the CLI the structured read invokes, so gh is what has to hang for the
  # fallback to have anything to bound. gh-axi hangs identically so no forge CLI
  # on the host's own PATH can answer this case instead.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 5
printf '%s\n' '{"state":"OPEN"}'
SH
  cp "$fakebin/gh" "$fakebin/gh-axi"
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"

  started=$(date +%s)
  rc=0
  FM_PR_STATUS_FORCE_FALLBACK=1 FM_PR_STATUS_TIMEOUT=1 PATH="$fakebin:$PATH" \
    fm "$home" "$PRSTATUS" refresh "$id" >/dev/null 2>&1 || rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -ne 0 ] || fail "the fallback timeout accepted a hung forge call"
  [ "$elapsed" -lt 4 ] || fail "the fallback timeout did not bound the forge call (${elapsed}s)"
  pass "the portable fallback bounds forge calls when GNU timeout is unavailable"
}

# --- durable history --------------------------------------------------------

test_history_projection() {
  local home out
  home=$(make_home history)
  seed_ship_task "$home" older
  seed_ship_task "$home" newer
  fm "$home" "$MANIFEST" write older --completed-at 2026-07-01T00:00:00Z >/dev/null
  fm "$home" "$MANIFEST" write newer --completed-at 2026-07-09T00:00:00Z >/dev/null

  out=$(fm "$home" "$MANIFEST" list)
  [ "$(printf '%s' "$out" | jq -r '.schema')" = fm-outcome-history.v1 ] || fail "history schema is wrong"
  [ "$(printf '%s' "$out" | jq -r '.records[0].task_id')" = newer ] \
    || fail "history must be ordered newest completion first"
  [ "$(printf '%s' "$out" | jq -r '.total')" = 2 ] || fail "history total is wrong"
  printf '%s' "$out" | jq -e '.truncated == false' >/dev/null || fail "unbounded history reported truncation"

  out=$(fm "$home" "$MANIFEST" list --limit 1)
  printf '%s' "$out" | jq -e '.shown == 1 and .total == 2 and .truncated == true' >/dev/null \
    || fail "a bounded history did not disclose truncation"

  # A record that no longer parses is disclosed, never silently dropped.
  mkdir -p "$home/data/broken"
  printf 'not json at all\n' > "$home/data/broken/outcome.json"
  mkdir -p "$home/data/wrongschema"
  printf '{"schema":"something-else"}\n' > "$home/data/wrongschema/outcome.json"
  out=$(fm "$home" "$MANIFEST" list)
  [ "$(printf '%s' "$out" | jq -r '.total')" = 2 ] || fail "an unreadable manifest was counted as a record"
  [ "$(printf '%s' "$out" | jq '[.malformed[].id] | sort | join(",")' -r)" = "broken,wrongschema" ] \
    || fail "unreadable manifests were not disclosed: $(printf '%s' "$out" | jq -c '.malformed')"
  pass "durable history orders newest first, bounds with disclosure, and surfaces unreadable records"
}

test_history_survives_record_removal() {
  local home id out
  home=$(make_home survives)
  id=ship-e
  seed_ship_task "$home" "$id"
  printf 'done: ready\n' > "$home/state/$id.status"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] $id - Torn down task (repo: alpha) (kind: ship) (done 2026-07-02)
EOF
  fm "$home" "$WORKITEM" add "$id" https://github.com/acme/widget/issues/18 >/dev/null
  fm "$home" "$WORKITEM" add "$id" https://gitlab.example.com/group/sub/proj/-/issues/7 \
    --origin pr-linked >/dev/null
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed"

  # Simulate exactly what teardown and backlog pruning remove.
  rm -f "$home/state/$id.meta" "$home/state/$id.status"
  printf '## Done\n' > "$home/data/backlog.md"

  out=$(fm "$home" "$MANIFEST" list)
  [ "$(printf '%s' "$out" | jq -r '.records[0].task_id')" = "$id" ] \
    || fail "the task left durable history when its volatile records were removed"
  [ "$(printf '%s' "$out" | jq -r '.records[0].title')" = "Torn down task" ] \
    || fail "the manifest did not retain the title after the backlog entry was pruned"
  [ "$(printf '%s' "$out" | jq -r '.records[0].attribution.endpoint.target')" = "firstmate:fm-$id" ] \
    || fail "the manifest did not retain the session reference needed for usage attribution"

  # Work-item references cross into durable history intact, across both forges
  # and with enrichment still absent.
  printf '%s' "$out" | jq -e '.records[0].work_items
    | .schema == "fm-work-items.v1"
      and (.references | length) == 2
      and (.references | map(.forge) | sort) == ["github","gitlab"]
      and (.references | map(.origin) | sort) == ["intake","pr-linked"]
      and (.references | map(.enrichment.title) | all(. == null))' >/dev/null \
    || fail "work-item references did not survive into durable history: $(printf '%s' "$out" | jq -c '.records[0].work_items')"
  pass "a task, its attribution, and its work items stay in durable history after the volatile records are gone"
}

# A history read that loses its records must fail, not return an empty list.
#
# This is the shape the dashboard's History panel actually broke in: under the
# service unit's read-only filesystem, bash could not write the temp file a
# here-string larger than a pipe buffer needs, fed the projection loop nothing,
# and the read returned zero records with total 61 and exit 0. The panel had no
# way to tell that from a fleet that has finished nothing, so it rendered
# "Nothing has completed in this home" over sixty-one completion records.
#
# The projection no longer uses a here-string, so the fault is injected here
# rather than reproduced: an ordering step that succeeds while emitting nothing
# stands for any way records can be lost between disk and the result. What is
# pinned is the response - refuse - not the mechanism that caused it.
test_history_refuses_to_report_a_lost_read_as_an_empty_fleet() {
  local home out rc stub real_jq
  home=$(make_home lostread)
  seed_ship_task "$home" kept
  fm "$home" "$MANIFEST" write kept --completed-at 2026-07-01T00:00:00Z >/dev/null

  out=$(fm "$home" "$MANIFEST" list) || fail "the unfaulted read must succeed"
  printf '%s' "$out" | jq -e '.total == 1 and .shown == 1' >/dev/null \
    || fail "the fixture must have a record to lose: $out"

  stub="$TMP_ROOT/lostread-bin"
  real_jq=$(command -v jq)
  mkdir -p "$stub"
  # The single quotes are the point: these lines are the stub's source, so the
  # expansions must survive into the file rather than happening here.
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for arg in "$@"; do\n'
    printf '  case "$arg" in *sort_by*) exit 0 ;; esac\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$real_jq"
  } > "$stub/jq"
  chmod +x "$stub/jq"

  rc=0
  out=$(PATH="$stub:$PATH" fm "$home" "$MANIFEST" list 2>&1) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a read that lost its records exited 0, which is what let the panel call the fleet empty: $out"
  printf '%s' "$out" | jq -e '.records == [] and .total > 0' >/dev/null 2>&1 \
    && fail "a read that lost its records still published an empty history document: $out"
  # A refusal that says nothing only moves the false absence: the operator
  # trades "nothing has completed" for "command exited 1" and still cannot tell
  # a lost read from an empty fleet. So the refusal has to name the discrepancy
  # it saw - the records it counted, where it counted them, and that none of
  # them arrived.
  assert_contains "$out" "none reached the result" \
    "the refusal did not say that counted records failed to arrive: $out"
  assert_contains "$out" "$home/data" \
    "the refusal did not name the directory it counted records in: $out"
  printf '%s' "$out" | grep -q '1 completed record' \
    || fail "the refusal did not name how many records it counted: $out"
  pass "a history read that loses its records refuses, and says what it counted, instead of reporting a fleet that finished nothing"
}

# --- secret safety ----------------------------------------------------------

test_no_secret_bearing_fields() {
  local home id sentinel out snap oversized_title oversized_source
  home=$(make_home secrets)
  id=ship-f
  sentinel=FMSECRETSENTINEL9271
  seed_ship_task "$home" "$id"

  # Plant the same sentinel in every credential-, prompt-, or payload-bearing
  # artifact a composer could plausibly reach, then prove none of it is emitted.
  # The crew's own status line is deliberately excluded: it is a single-line
  # supervisor-facing field firstmate designed and has always surfaced, not a
  # store of credentials or captured payloads.
  printf 'FMX_PAIRING_TOKEN=%s\n' "$sentinel" > "$home/.env"
  printf 'token=%s\n' "$sentinel" > "$home/state/$id.grok-turnend-token"
  printf 'token=%s\n' "$sentinel" > "$home/state/$id.kimi-turnend-token"
  printf 'trust=%s\n' "$sentinel" > "$home/state/$id.agy-trust"
  printf '%s\n' "$sentinel" > "$home/state/$id.check-trust"
  printf 'fm-pr-poll-registration-v2\n%s\n' "$sentinel" > "$home/state/$id.pr-poll-registration"
  printf '# brief\nAPI key: %s\nDo not leak this.\n' "$sentinel" > "$home/data/$id/brief.md"
  printf '# report\nThe credential was %s\n' "$sentinel" > "$home/data/$id/report.md"
  printf 'done: implementation complete\n' > "$home/state/$id.status"
  printf 'pr=https://github.com/acme/widget/pull/15\n' >> "$home/state/$id.meta"
  oversized_title="$(printf 'x%.0s' $(seq 1 241))$sentinel"
  oversized_source="$(printf 'x%.0s' $(seq 1 41))$sentinel"
  jq -n --arg id "$id" --arg title "$oversized_title" '
    {schema:"fm-work-items.v1",task_id:$id,references:[{
      url:"https://github.com/acme/widget/issues/18",forge:"github",host:"github.com",
      path:"acme/widget",owner:"acme",repo:"widget",number:18,kind:"issue",origin:"intake",
      enrichment:{title:$title,state:"open",observed_at:"2026-07-04T00:00:00Z",source:"gh"}}]}' \
    > "$home/data/$id/work-items.json"
  jq -n --arg source "$oversized_source" '
    {schema:"fm-pr-status.v1",url:"https://github.com/acme/widget/pull/15",provider:"github",
     host:"github.com",path:"acme/widget",number:15,
     status:{state:"open",draft:false,review:"approved",checks:"passing",mergeable:"mergeable",
             head:"abcdef1234567890abcdef1234567890abcdef12",observed_at:"2026-07-04T00:00:00Z",source:$source}}' \
    > "$home/state/$id.pr-status"

  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id")
  assert_not_contains "$out" "$sentinel" "the manifest emitted a secret-bearing value"
  printf '%s' "$out" | jq -e '.work_items.references == []
    and .pr.status.state == "unknown" and .pr.status.source == "absent"' >/dev/null \
    || fail "non-conforming allowlisted values were not replaced with safe projections"

  snap=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$SNAPSHOT" --json) || fail "snapshot failed"
  assert_not_contains "$snap" "$sentinel" "the fleet snapshot emitted a secret-bearing value"
  # The report is referenced by path; its body is never inlined.
  assert_contains "$out" "$home/data/$id/report.md" "the manifest lost the report pointer"
  pass "neither the manifest nor the snapshot emits credential, brief, or payload content"
}

test_free_text_is_bounded_and_single_line() {
  local home id out detail
  home=$(make_home freetext)
  id=ship-g
  seed_ship_task "$home" "$id"
  {
    printf 'done: '
    printf 'x%.0s' $(seq 1 400)
    printf '\n'
  } > "$home/state/$id.status"
  fm "$home" "$MANIFEST" write "$id" >/dev/null || fail "manifest write failed"
  out=$(fm "$home" "$MANIFEST" show "$id")
  detail=$(printf '%s' "$out" | jq -r '.outcome.detail')
  [ "${#detail}" -le 240 ] || fail "a durable free-text field exceeded its cap: ${#detail} characters"
  case "$detail" in
    *$'\n'*|*$'\t'*) fail "a durable free-text field kept a control character" ;;
  esac
  pass "durable free text is capped and collapsed to a single line"
}

test_manifest_composition
test_manifest_gbrain_and_overrides
test_design_manifest_is_valid
test_design_manifest_carries_the_plugin_release
test_manifest_omits_an_unresolved_plugin_release
test_manifest_without_design_skills_stays_valid
test_secondmate_manifest_title_is_null
test_manifest_without_sessions_stays_valid
test_manifest_requires_metadata_and_allowlist
test_work_items_round_trip
test_work_item_rejects_unusable_urls
test_work_item_mutations_refuse_invalid_store
test_pr_status_normalization
test_pr_status_refresh_and_cache
test_gitlab_approval_state
test_pr_status_fallback_timeout
test_history_projection
test_history_survives_record_removal
test_history_refuses_to_report_a_lost_read_as_an_empty_fleet
test_no_secret_bearing_fields
test_free_text_is_bounded_and_single_line
printf '\nall fm-outcome-manifest tests passed\n'
