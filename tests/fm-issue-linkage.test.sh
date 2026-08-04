#!/usr/bin/env bash
# Tests for project-scoped work-item linkage across managed forges:
# bin/fm-issue-lib.sh, bin/fm-issue-ref.sh, bin/fm-issue-status.sh, and the
# bin/fm-brief.sh --work-item scaffold.
#
# The defect this whole suite exists to prevent: a bare "#42" is meaningless
# without a project, and resolving it against the wrong forge is silent. Every
# refusal case below is therefore as load-bearing as the success cases - a
# regression that starts guessing would still pass the happy paths.
#
# Matrix, driven by tests/fixtures/issue-linkage/projects-cross-forge.md:
#   (a) a GitHub project resolves a bare number through its declared tracker
#   (b) a self-hosted Gitea project does the same on its own host
#   (c) a clone directory that disagrees with the declared tracker follows the
#       declaration (the renamed-repository case)
#   (d) a git remote pointing somewhere else never decides the tracker
#   (e) a project with no declared tracker refuses a bare reference
#   (f) tracker=none refuses with its own distinct reason
#   (g) a malformed declaration - unparseable, empty, or doubled - is reported,
#       never read as "undeclared" and never resolved by position
#   (h) malformed references are refused with an actionable message
#   (i) owner/repo#N, full URLs, and forge-prefixed URLs resolve
#   (j) an ambiguous self-hosted URL is refused rather than guessed
#   (k) several references and zero references both work, and zero still answers
#       a json caller with a parseable document
#   (l) the tracker token does not disturb delivery-posture parsing
#   (m) briefs carry resolved markers and refuse unresolved ones, and a spawn
#       records them in task metadata
#   (n) status enrichment degrades cleanly on every failure mode
#   (o) status enrichment caches, so repeated refreshes inside the TTL ask the
#       forge once, and coarsely spaces the live lookups that miss the cache
#   (p) forge credentials are restrictive, never inherited, never in argv
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ISSUE_REF="$ROOT/bin/fm-issue-ref.sh"
ISSUE_STATUS="$ROOT/bin/fm-issue-status.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
FIXTURE_REGISTRY="$ROOT/tests/fixtures/issue-linkage/projects-cross-forge.md"
TMP_ROOT=$(fm_test_tmproot fm-issue-linkage)

REG_HOME="$TMP_ROOT/home"
mkdir -p "$REG_HOME/data"
cp "$FIXTURE_REGISTRY" "$REG_HOME/data/projects.md"

# Resolve <ref>... for <project> against the cross-forge fixture registry.
resolve() {  # <project> [args...]
  local project=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$REG_HOME/data" \
    "$ISSUE_REF" --project "$project" "$@"
}

# --- resolution -------------------------------------------------------------

test_github_project_resolves_bare_number() {
  local out
  out=$(resolve gh-project 42) || fail "gh-project: a bare number did not resolve"
  [ "$out" = 'work_item=declared|github|https://github.com/HelloWorldSungin/gh-project/issues/42' ] \
    || fail "gh-project: resolved to the wrong identity: $out"
  out=$(resolve gh-project '#42') || fail "gh-project: the #N form did not resolve"
  [ "$out" = 'work_item=declared|github|https://github.com/HelloWorldSungin/gh-project/issues/42' ] \
    || fail "gh-project: #N and N disagreed: $out"
  pass "a GitHub project resolves a bare reference through its declared tracker"
}

test_gitea_project_resolves_on_its_own_host() {
  local out
  out=$(resolve gitea-project 7 --format url) || fail "gitea-project: a bare number did not resolve"
  [ "$out" = 'https://gitea.example.com/DuckKingOri/gitea-project/issues/7' ] \
    || fail "gitea-project: resolved to the wrong host or path: $out"
  pass "a self-hosted Gitea project resolves on its own host"
}

# The clone directory says renamed-clone; the tracker says renamed-upstream.
# Anything that derived identity from the directory name would fail here.
test_declared_tracker_beats_the_clone_directory_name() {
  local out
  out=$(resolve renamed-clone 42 --format url) || fail "renamed-clone: did not resolve"
  [ "$out" = 'https://github.com/HelloWorldSungin/renamed-upstream/issues/42' ] \
    || fail "renamed-clone: followed the clone directory instead of the declaration: $out"
  pass "a renamed repository resolves to its declared tracker, not its clone directory name"
}

# A project may be mirrored on one host with its issues tracked on another. The
# registry declaration is the only authority, so a real git remote pointing at a
# different forge must change nothing.
test_git_remote_never_decides_the_tracker() {
  local repo out
  repo="$TMP_ROOT/mirror-repo"
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin https://github.com/SomeoneElse/mirrored-project.git
  out=$(cd "$repo" && resolve mirrored-project 3 --format url) \
    || fail "mirrored-project: did not resolve"
  [ "$out" = 'https://gitea.example.com/DuckKingOri/mirrored-project/issues/3' ] \
    || fail "mirrored-project: the git remote leaked into tracker resolution: $out"
  pass "a git remote on another host never decides where issues are tracked"
}

# The core acceptance criterion: refuse rather than resolve to the wrong forge.
test_undeclared_tracker_refuses_bare_reference() {
  local out rc
  set +e
  out=$(resolve untracked-project '#5' 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "untracked-project: a bare reference must be refused"
  assert_contains "$out" 'untracked-project' "untracked-project: refusal did not name the project"
  assert_contains "$out" 'declare its issue tracker' "untracked-project: refusal was not actionable"
  assert_not_contains "$out" 'work_item=' "untracked-project: a reference was recorded anyway"
  pass "a project with no declared tracker refuses a bare reference with a clear reason"
}

test_explicit_none_refuses_with_its_own_reason() {
  local out rc
  set +e
  out=$(resolve trackerless-project '#5' 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "trackerless-project: a bare reference must be refused"
  assert_contains "$out" 'declares no issue tracker' \
    "trackerless-project: tracker=none was not distinguished from undeclared"
  pass "tracker=none refuses with a reason distinct from an absent declaration"
}

# A typo must never read as "this project has no tracker": that would silently
# downgrade a configured project into the refusing path and hide the bug.
test_malformed_declaration_is_reported_not_treated_as_absent() {
  local project out rc
  for project in malformed-project empty-tracker-project; do
    set +e
    out=$(resolve "$project" '#5' 2>&1)
    rc=$?
    set -e
    expect_code 2 "$rc" "$project: a malformed declaration must fail"
    assert_contains "$out" 'malformed tracker declaration' \
      "$project: the declaration bug was not reported"
    set +e
    out=$(resolve "$project" --show-tracker 2>&1)
    rc=$?
    set -e
    expect_code 2 "$rc" "$project: --show-tracker must report the malformed declaration"
  done
  pass "a malformed tracker declaration is reported rather than read as undeclared"
}

# Two tracker= tokens in one entry name no authoritative tracker. A parser that
# stops at the first match resolves happily and silently, and the wrong tracker
# is only discovered when an issue is closed on it, so the refusal is the whole
# point: both the resolution path and --show-tracker must decline to choose.
test_duplicate_tracker_declaration_is_refused() {
  local out rc
  set +e
  out=$(resolve double-tracker-project '#5' 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "two tracker= tokens in one entry must fail"
  assert_contains "$out" 'malformed tracker declaration' \
    "a duplicate declaration was not reported as malformed"
  assert_contains "$out" 'more than one tracker= token' \
    "the refusal did not name the duplicate declaration"
  assert_not_contains "$out" 'work_item=' \
    "a duplicate declaration still resolved a reference"

  set +e
  out=$(resolve double-tracker-project --show-tracker 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "--show-tracker must report a duplicate declaration"
  [ "$out" != 'github:github.com/HelloWorldSungin/first-tracker' ] \
    || fail "--show-tracker picked the first of two declarations"
  [ "$out" != 'gitea:gitea.example.com/DuckKingOri/second-tracker' ] \
    || fail "--show-tracker picked the last of two declarations"
  pass "two tracker declarations in one entry are refused rather than resolved by position"
}

# --show-tracker answers with a raw declaration, which has no representation in
# any --format shape. A script that asked for json must not silently receive a
# bare line instead, so the combination is a usage error rather than a surprise.
test_show_tracker_refuses_a_format_it_cannot_honour() {
  local out rc
  set +e
  out=$(resolve gitea-project --show-tracker --format json 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "--show-tracker with --format json must be a usage error"
  assert_contains "$out" 'takes no --format' \
    "the refusal did not name the flag combination"
  assert_not_contains "$out" 'gitea:gitea.example.com' \
    "--show-tracker printed a bare declaration to a caller that asked for json"
  pass "--show-tracker refuses a --format it cannot honour"
}

test_malformed_references_are_refused() {
  local ref out rc
  for ref in 'nonsense' '#' '#0' '#-3' 'a/b/c#1' 'owner/repo#' 'owner/repo#1#2' '#9999999999999'; do
    set +e
    out=$(resolve gh-project "$ref" 2>&1)
    rc=$?
    set -e
    expect_code 2 "$rc" "malformed reference '$ref' was accepted"
    assert_contains "$out" 'malformed' "reference '$ref': refusal did not say it was malformed"
  done
  pass "malformed references are refused with an actionable message"
}

test_qualified_reference_forms_resolve() {
  local out
  out=$(resolve gh-project 'HelloWorldSungin/other-repo#3' --format url) \
    || fail "owner/repo#N did not resolve"
  [ "$out" = 'https://github.com/HelloWorldSungin/other-repo/issues/3' ] \
    || fail "owner/repo#N resolved wrongly: $out"

  out=$(resolve gh-project 'https://github.com/x/y/issues/9' --format url) \
    || fail "a full GitHub URL did not resolve"
  [ "$out" = 'https://github.com/x/y/issues/9' ] || fail "full URL round-trip failed: $out"

  out=$(resolve gitea-project 'https://gitea.example.com/DuckKingOri/gitea-project/issues/8' --format url) \
    || fail "a full Gitea URL did not resolve against its own project"
  [ "$out" = 'https://gitea.example.com/DuckKingOri/gitea-project/issues/8' ] \
    || fail "Gitea URL round-trip failed: $out"

  out=$(resolve gh-project 'gitea:https://gitea.example.com/a/b/issues/3' --format url) \
    || fail "a forge-prefixed URL did not resolve"
  [ "$out" = 'https://gitea.example.com/a/b/issues/3' ] \
    || fail "forge-prefixed URL resolved wrongly: $out"

  out=$(resolve gh-project 'github:https://github.example.com/a/b/issues/3' --format url) \
    || fail "an explicitly prefixed self-hosted GitHub URL did not resolve"
  [ "$out" = 'https://github.example.com/a/b/issues/3' ] \
    || fail "self-hosted GitHub URL round-trip failed: $out"

  out=$(resolve gitlab-project 5 --format url) || fail "a nested GitLab namespace did not resolve"
  [ "$out" = 'https://gitlab.example.com/group/subgroup/proj/-/issues/5' ] \
    || fail "GitLab nested path resolved wrongly: $out"
  pass "owner/repo#N, full URLs, forge-prefixed URLs, and nested GitLab paths resolve"
}

# https://<host>/<owner>/<repo>/issues/<n> is a shape several forges serve, so
# it is only resolvable with a stated forge. Guessing "it looks like Gitea" from
# an unfamiliar host is exactly the failure this story removes.
test_ambiguous_self_hosted_url_is_refused_not_guessed() {
  local out rc
  set +e
  out=$(resolve gh-project 'https://forge.example.com/a/b/issues/3' 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an ambiguous self-hosted URL was resolved by guessing"
  assert_contains "$out" 'prefix it with a forge' \
    "the ambiguous-URL refusal did not offer the qualified form"

  set +e
  out=$(resolve gitea-project 'https://other.example.com/a/b/issues/3' 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a foreign host inherited the project's Gitea forge"
  assert_contains "$out" 'prefix it with a forge' \
    "the foreign-host refusal did not offer the qualified form"

  out=$(resolve gitea-project 'https://gitea.example.com/a/b/issues/3' --format url) \
    || fail "the declared Gitea host did not supply its implicit forge"
  [ "$out" = 'https://gitea.example.com/a/b/issues/3' ] \
    || fail "the declared-host URL resolved wrongly: $out"
  pass "an ambiguous self-hosted issue URL is refused rather than guessed"
}

test_owner_repo_form_is_refused_for_nested_gitlab() {
  local out rc
  set +e
  out=$(resolve gitlab-project 'group/proj#4' 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "owner/repo#N must not address a nested GitLab namespace"
  assert_contains "$out" 'nested GitLab namespace' \
    "the GitLab refusal did not explain why owner/repo#N cannot work"
  pass "owner/repo#N is refused for a nested GitLab namespace"
}

test_multiple_and_zero_references() {
  local out count
  out=$(resolve gh-project 1 2 'https://github.com/x/y/issues/3') \
    || fail "multiple references did not resolve"
  count=$(printf '%s\n' "$out" | grep -c '^work_item=')
  [ "$count" -eq 3 ] || fail "expected 3 resolved references, got $count"
  printf '%s\n' "$out" | head -n 1 | grep -q '/issues/1$' \
    || fail "resolved references lost their input order"

  out=$(resolve gh-project) || fail "a task with no references must succeed"
  [ -z "$out" ] || fail "a task with no references emitted output: $out"
  # The manifest consumer must still get a parseable document with no items.
  out=$(resolve gh-project --format json) || fail "json with no references must succeed"
  [ "$out" = '[]' ] || fail "json with no references was not the empty array: $out"
  pass "a task may carry several references or none"
}

# One unresolvable reference must fail the whole call, so a partially resolved
# set is never recorded as if it were complete.
test_one_bad_reference_fails_the_whole_set() {
  local out rc
  set +e
  out=$(resolve gh-project 1 'nonsense' 3 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a bad reference in a set did not fail the call"
  assert_not_contains "$out" 'work_item=' \
    "a partially resolved set was emitted alongside the refusal"
  pass "one unresolvable reference refuses the whole set"
}

test_json_output_carries_the_manifest_fields() {
  local out
  command -v jq >/dev/null 2>&1 || { pass "json manifest fields (skipped: jq absent)"; return; }
  out=$(resolve gitea-project 7 --format json) || fail "json format failed"
  printf '%s' "$out" | jq -e '.[0]
    | .url == "https://gitea.example.com/DuckKingOri/gitea-project/issues/7"
    and .forge == "gitea" and .host == "gitea.example.com"
    and .path == "DuckKingOri/gitea-project" and .owner == "DuckKingOri"
    and .repo == "gitea-project" and .number == 7 and .origin == "declared"' >/dev/null \
    || fail "json record did not carry the expected manifest fields: $out"
  out=$(resolve gitlab-project 5 --format json) || fail "gitlab json format failed"
  printf '%s' "$out" | jq -e '.[0].owner == null and .[0].repo == null and .[0].forge == "gitlab"' >/dev/null \
    || fail "a nested GitLab record must carry a null owner/repo pair: $out"
  pass "json output carries the fields the outcome manifest transports"
}

test_show_tracker_reports_declaration_and_absence() {
  local out rc
  out=$(resolve gitea-project --show-tracker) || fail "--show-tracker failed for a declared project"
  [ "$out" = 'gitea:gitea.example.com/DuckKingOri/gitea-project' ] \
    || fail "--show-tracker printed the wrong declaration: $out"
  set +e
  out=$(resolve untracked-project --show-tracker 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "--show-tracker must report absence with its own exit code"
  pass "--show-tracker reports a declaration and distinguishes absence"
}

# The tracker token rides inside the existing bracket annotation, so delivery
# posture parsing must be untouched by its presence.
test_tracker_token_does_not_disturb_delivery_posture() {
  local out
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$REG_HOME/data" \
    "$ROOT/bin/fm-project-mode.sh" gh-project 2>/dev/null)
  [ "$out" = 'no-mistakes on' ] || fail "tracker token changed delivery posture: $out"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$REG_HOME/data" \
    "$ROOT/bin/fm-project-mode.sh" gitea-project 2>/dev/null)
  [ "$out" = 'direct-PR off' ] || fail "tracker token changed delivery posture: $out"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$REG_HOME/data" \
    "$ROOT/bin/fm-project-mode.sh" trackerless-project 2>/dev/null)
  [ "$out" = 'direct-PR off' ] || fail "tracker=none changed delivery posture: $out"
  pass "a tracker declaration does not disturb delivery-posture parsing"
}

# --- brief scaffolding ------------------------------------------------------

test_brief_records_resolved_work_items() {
  local home brief out
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  out=$(resolve gitea-project 7 --format brief) || fail "brief format failed"
  [ "$out" = 'gitea:https://gitea.example.com/DuckKingOri/gitea-project/issues/7' ] \
    || fail "brief format emitted the wrong argument: $out"

  FM_HOME="$home" "$BRIEF" wi-task gitea-project --mode no-mistakes \
    --work-item "$out" \
    --work-item 'github:https://github.com/x/y/issues/9' >/dev/null \
    || fail "brief scaffolding with work items failed"
  brief="$home/data/wi-task/brief.md"
  assert_grep '<!-- firstmate-work-item=gitea:https://gitea.example.com/DuckKingOri/gitea-project/issues/7 -->' \
    "$brief" "brief lost the Gitea work-item marker"
  assert_grep '<!-- firstmate-work-item=github:https://github.com/x/y/issues/9 -->' \
    "$brief" "brief lost the GitHub work-item marker"
  assert_grep 'https://gitea.example.com/DuckKingOri/gitea-project/issues/7' \
    "$brief" "brief did not show the worker the full tracker URL"
  assert_grep 'Reference each full URL in the PR body' \
    "$brief" "brief did not require full tracker URLs in the PR body"
  assert_no_grep 'comment on each one with a substantive summary' \
    "$brief" "brief added cross-forge tracker write-back"
  assert_no_grep 'A bare "done" comment does not satisfy this contract' \
    "$brief" "brief retained cross-forge comment requirements"
  pass "a ship brief records every resolved work item as a marker and a full URL"
}

test_brief_refuses_unresolved_work_items() {
  local home out rc
  home="$TMP_ROOT/brief-refuse"
  mkdir -p "$home/data"
  for out in '#5' 'owner/repo#5' 'https://forge.example.com/a/b/issues/1'; do
    set +e
    FM_HOME="$home" "$BRIEF" "bad-$RANDOM" someproject --mode no-mistakes \
      --work-item "$out" >/dev/null 2>"$TMP_ROOT/brief-refuse.err"
    rc=$?
    set -e
    expect_code 1 "$rc" "brief accepted an unresolved work item '$out'"
    assert_grep 'resolved <forge>:<url>' "$TMP_ROOT/brief-refuse.err" \
      "brief refusal for '$out' did not point at intake resolution"
  done
  pass "a brief refuses any work item that intake has not already resolved"
}

# --- spawn: recording resolved references in task metadata ------------------
#
# These drive bin/fm-spawn.sh against a real isolated git worktree with a fake
# tmux, so the recorded metadata is the real thing rather than a reconstruction.

make_spawn_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Echoes "<home>|<project>|<worktree>|<fakebin>|<id>". <registry-line> seeds the
# home's own registry so the spawn resolves the project's tracker for real.
make_spawn_case() {  # <name> <registry-line> <brief-extra-line>...
  local name=$1 registry=$2 home proj wt fakebin id
  shift 2
  home="$TMP_ROOT/spawn-$name/home"
  proj="$TMP_ROOT/spawn-$name/projects/proj"
  wt="$TMP_ROOT/spawn-$name/wt"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-$name/fake")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  printf '# Projects\n\n%s\n' "$registry" > "$home/data/projects.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  {
    printf 'brief for %s\n\n' "$id"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf '\nDelivery contract: mode=no-mistakes\n'
  } > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$id"
}

run_spawn() {  # <home> <wt> <fakebin> <id> <project-dir>
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

test_spawn_records_resolved_work_items_in_metadata() {
  local record home proj wt fakebin id out meta
  record=$(make_spawn_case gitea \
    '- proj [no-mistakes tracker=gitea:gitea.example.com/DuckKingOri/proj] - fixture (added 2026-08-04)' \
    '<!-- firstmate-work-item=gitea:https://gitea.example.com/DuckKingOri/proj/issues/7 -->' \
    '<!-- firstmate-work-item=github:https://github.com/x/y/issues/9 -->')
  IFS='|' read -r home proj wt fakebin id <<EOF
$record
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj") || fail "spawn failed: $out"
  meta="$home/state/$id.meta"
  [ -f "$meta" ] || fail "spawn wrote no task metadata"
  assert_grep 'work_item=declared|gitea|https://gitea.example.com/DuckKingOri/proj/issues/7' \
    "$meta" "the Gitea work item was not recorded in task metadata"
  assert_grep 'work_item=declared|github|https://github.com/x/y/issues/9' \
    "$meta" "the GitHub work item was not recorded in task metadata"
  [ "$(grep -c '^work_item=' "$meta")" -eq 2 ] \
    || fail "expected exactly two recorded work items in $meta"
  pass "a spawn records every resolved work item in task metadata"
}

# The legacy bare marker means "whichever repository the PR lands in". When the
# project declares a tracker, the spawn upgrades it to that full identity, which
# is what stops a mirrored project's bookkeeping reaching the wrong forge.
test_spawn_upgrades_a_legacy_issue_marker_through_the_declared_tracker() {
  local record home proj wt fakebin id out meta
  record=$(make_spawn_case legacy \
    '- proj [no-mistakes tracker=github:github.com/HelloWorldSungin/renamed-upstream] - fixture (added 2026-08-04)' \
    '<!-- firstmate-task-issue=42 -->')
  IFS='|' read -r home proj wt fakebin id <<EOF
$record
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj") || fail "spawn failed: $out"
  meta="$home/state/$id.meta"
  assert_grep 'issue=42' "$meta" "the legacy issue number stopped being recorded"
  assert_grep 'work_item=declared|github|https://github.com/HelloWorldSungin/renamed-upstream/issues/42' \
    "$meta" "the legacy marker was not upgraded through the declared tracker"
  pass "a spawn upgrades a legacy issue marker through the project's declared tracker"
}

# Without a declaration the bare number cannot be project-scoped, so the spawn
# must say so rather than record something that only looks tracker-backed.
test_spawn_warns_when_a_legacy_marker_has_no_declared_tracker() {
  local record home proj wt fakebin id out meta
  record=$(make_spawn_case nodecl \
    '- proj [no-mistakes] - fixture with no tracker (added 2026-08-04)' \
    '<!-- firstmate-task-issue=42 -->')
  IFS='|' read -r home proj wt fakebin id <<EOF
$record
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj") || fail "spawn failed: $out"
  meta="$home/state/$id.meta"
  assert_grep 'issue=42' "$meta" "the legacy issue number stopped being recorded"
  assert_no_grep 'work_item=' "$meta" \
    "an unresolvable legacy marker was recorded as a tracker-backed work item"
  assert_contains "$out" 'declares no issue tracker in data/projects.md' \
    "the missing tracker declaration was not reported"
  pass "a spawn reports a legacy marker it cannot resolve instead of inventing a tracker"
}

test_spawn_refuses_a_malformed_work_item_marker() {
  local record home proj wt fakebin id out rc
  record=$(make_spawn_case badmarker \
    '- proj [no-mistakes tracker=github:github.com/o/r] - fixture (added 2026-08-04)' \
    '<!-- firstmate-work-item=not-a-reference -->')
  IFS='|' read -r home proj wt fakebin id <<EOF
$record
EOF
  set +e
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn accepted a malformed work-item marker"
  assert_contains "$out" 'unresolvable' "the malformed marker refusal was not explicit"
  assert_absent "$home/state/$id.meta" \
    "spawn recorded task metadata despite refusing the work-item marker"
  pass "a spawn refuses a work-item marker it cannot resolve, before creating anything"
}

# --- status enrichment ------------------------------------------------------

status_case() {  # <name> -> echoes case dir with state/, config/, fakebin/
  local name=$1 case_dir
  case_dir="$TMP_ROOT/status-$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

run_status() {  # <case-dir> [args...]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_ISSUE_STATUS_MIN_INTERVAL="${FM_ISSUE_STATUS_MIN_INTERVAL:-0}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$ISSUE_STATUS" "$@"
}

fake_gh_axi_issue() {  # <case-dir> <state> <title>
  cat > "$1/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
[ -z "\${FM_TEST_GH_CALLS:-}" ] || printf '%s\n' "\$*" >> "\$FM_TEST_GH_CALLS"
printf 'issue:\n  number: 1\n  title: "%s"\n  state: %s\n' '$3' '$2'
exit 0
SH
  chmod +x "$1/fakebin/gh-axi"
}

fake_gh_axi_failing() {  # <case-dir>
  cat > "$1/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo 'gh: Not Found (HTTP 404)' >&2
exit 1
SH
  chmod +x "$1/fakebin/gh-axi"
}

fake_gh_axi_hanging() {  # <case-dir>
  cat > "$1/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
SH
  chmod +x "$1/fakebin/gh-axi"
}

# A curl stub that answers with a fixed HTTP code and body, and records both its
# arguments and anything handed to it on stdin so credential handling can be
# asserted without a real forge.
#
# It reads stdin ONLY when real curl would: `-K -` is the flag that makes curl
# take its config from stdin. An unconditional `cat` here blocks forever on the
# unauthenticated path, because nothing is piped in and the inherited stdin
# never reaches EOF - a hang whose appearance depends on how the suite was
# launched, which is exactly the kind of flakiness a test must not carry.
fake_curl() {  # <case-dir> <http-code> <body>
  cat > "$1/fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_CURL_ARGS"
for arg in "\$@"; do
  if [ "\$arg" = -K ]; then
    cat >> "\$FM_TEST_CURL_STDIN"
    break
  fi
done
printf '%s\n%s' '$3' '$2'
exit 0
SH
  chmod +x "$1/fakebin/curl"
}

fake_curl_unreachable() {  # <case-dir>
  cat > "$1/fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$1/fakebin/curl"
}

test_github_status_enrichment() {
  local case_dir out
  case_dir=$(status_case gh-ok)
  fake_gh_axi_issue "$case_dir" open 'Add the thing'
  out=$(run_status "$case_dir" 'declared|github|https://github.com/x/y/issues/9') \
    || fail "github enrichment failed"
  assert_contains "$out" 'ok' "github enrichment did not report ok"
  assert_contains "$out" 'open' "github enrichment lost the open/closed state"
  assert_contains "$out" 'Add the thing' "github enrichment lost the title"
  pass "GitHub status enrichment returns the issue title and state"
}

test_self_hosted_github_status_is_reported_without_a_live_call() {
  local case_dir out
  case_dir=$(status_case gh-self-hosted)
  fake_gh_axi_issue "$case_dir" open 'Wrong host'
  out=$(FM_TEST_GH_CALLS="$case_dir/gh-calls" run_status "$case_dir" \
    'declared|github|https://ghe.example.com/o/r/issues/5') \
    || fail "self-hosted GitHub status degradation failed"
  assert_contains "$out" 'https://ghe.example.com/o/r/issues/5' \
    "self-hosted GitHub status lost the canonical link"
  assert_contains "$out" 'not implemented for host ghe.example.com' \
    "self-hosted GitHub status did not name the unsupported host"
  assert_absent "$case_dir/gh-calls" \
    "self-hosted GitHub status was silently addressed to github.com"
  pass "self-hosted GitHub status is reported without a github.com lookup"
}

# Every failure mode must still hand back the link plus a readable reason, and
# must still exit 0 so no caller can stall on it.
test_status_degrades_cleanly_on_every_failure_mode() {
  local case_dir out rc
  case_dir=$(status_case gh-fail)
  fake_gh_axi_failing "$case_dir"
  set +e
  out=$(run_status "$case_dir" 'declared|github|https://github.com/x/y/issues/9')
  rc=$?
  set -e
  expect_code 0 "$rc" "a failed GitHub lookup must not fail the command"
  assert_contains "$out" 'https://github.com/x/y/issues/9' "the plain link was lost on failure"
  assert_contains "$out" 'unavailable' "a failed lookup was not marked unavailable"

  case_dir=$(status_case gitea-404)
  fake_curl "$case_dir" 404 '{"message":"not found"}'
  set +e
  out=$(FM_TEST_CURL_ARGS="$case_dir/args" FM_TEST_CURL_STDIN="$case_dir/stdin" \
    run_status "$case_dir" 'declared|gitea|https://gitea.example.com/a/b/issues/3')
  rc=$?
  set -e
  expect_code 0 "$rc" "a deleted issue must not fail the command"
  assert_contains "$out" 'not found' "a 404 did not explain itself"

  case_dir=$(status_case gitea-unauthorized)
  fake_curl "$case_dir" 403 '{"message":"forbidden"}'
  set +e
  out=$(FM_TEST_CURL_ARGS="$case_dir/args" FM_TEST_CURL_STDIN="$case_dir/stdin" \
    run_status "$case_dir" 'declared|gitea|https://gitea.example.com/a/b/issues/3')
  rc=$?
  set -e
  expect_code 0 "$rc" "an unauthorized host must not fail the command"
  assert_contains "$out" 'credential' "an unauthorized host did not name the credential problem"

  case_dir=$(status_case gitea-unreachable)
  fake_curl_unreachable "$case_dir"
  set +e
  out=$(run_status "$case_dir" 'declared|gitea|https://gitea.example.com/a/b/issues/3')
  rc=$?
  set -e
  expect_code 0 "$rc" "an unreachable host must not fail the command"
  assert_contains "$out" 'unreachable' "an unreachable host did not say so"

  case_dir=$(status_case gitlab-unsupported)
  set +e
  out=$(run_status "$case_dir" 'declared|gitlab|https://gitlab.example.com/g/p/-/issues/4')
  rc=$?
  set -e
  expect_code 0 "$rc" "a forge without an adapter must not fail the command"
  assert_contains "$out" 'https://gitlab.example.com/g/p/-/issues/4' \
    "an unsupported forge lost its plain link"
  assert_contains "$out" 'not implemented' "an unsupported forge did not explain itself"

  case_dir=$(status_case malformed-record)
  set +e
  out=$(run_status "$case_dir" 'this-is-not-a-record')
  rc=$?
  set -e
  expect_code 0 "$rc" "a malformed record must not fail the command"
  assert_contains "$out" 'malformed work-item record' "a malformed record was not reported"
  pass "status enrichment degrades to a link plus a reason on every failure mode"
}

test_github_status_lookup_is_bounded() {
  local case_dir out rc started elapsed
  case_dir=$(status_case gh-timeout)
  fake_gh_axi_hanging "$case_dir"
  started=$(date +%s)
  set +e
  out=$(FM_ISSUE_STATUS_TIMEOUT=1 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9')
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "a timed-out GitHub lookup must not fail the command"
  [ "$elapsed" -lt 5 ] || fail "a hung GitHub lookup exceeded its bound (${elapsed}s)"
  assert_contains "$out" 'https://github.com/x/y/issues/9' \
    "a timed-out lookup lost its canonical URL"
  assert_contains "$out" 'unavailable' "a timed-out lookup was not marked unavailable"
  assert_contains "$out" 'timed out after 1s' "a timed-out lookup did not name its deadline"
  pass "a TERM-ignoring GitHub lookup degrades within the configured deadline"
}

test_gitea_status_enrichment_and_title_sanitizing() {
  local case_dir out
  command -v jq >/dev/null 2>&1 || { pass "gitea enrichment (skipped: jq absent)"; return; }
  case_dir=$(status_case gitea-ok)
  # A title carrying a tab and a newline would otherwise forge extra columns.
  fake_curl "$case_dir" 200 '{"state":"closed","title":"first\tsecond\nthird"}'
  out=$(FM_TEST_CURL_ARGS="$case_dir/args" FM_TEST_CURL_STDIN="$case_dir/stdin" \
    run_status "$case_dir" 'declared|gitea|https://gitea.example.com/a/b/issues/3') \
    || fail "gitea enrichment failed"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] \
    || fail "a title containing a newline produced extra output lines: $out"
  [ "$(printf '%s' "$out" | tr -cd '\t' | wc -c)" -eq 3 ] \
    || fail "a title containing a tab forged extra columns: $out"
  assert_contains "$out" 'closed' "gitea enrichment lost the issue state"
  pass "Gitea status enrichment reports state and neutralizes hostile titles"
}

# A long multibyte title must not be truncated mid-character: the fragment would
# be invalid UTF-8 in the JSON a dashboard parses.
test_long_multibyte_title_stays_valid_utf8() {
  local case_dir out long locale
  command -v jq >/dev/null 2>&1 || { pass "multibyte title truncation (skipped: jq absent)"; return; }
  long=$(printf '測%.0s' {1..300})
  for locale in default C; do
    case_dir=$(status_case "gitea-multibyte-$locale")
    fake_curl "$case_dir" 200 "{\"state\":\"open\",\"title\":\"$long\"}"
    if [ "$locale" = C ]; then
      out=$(LC_ALL=C FM_TEST_CURL_ARGS="$case_dir/args" FM_TEST_CURL_STDIN="$case_dir/stdin" \
        run_status "$case_dir" --format json \
        'declared|gitea|https://gitea.example.com/a/b/issues/3') \
        || fail "C-locale multibyte enrichment failed"
    else
      out=$(FM_TEST_CURL_ARGS="$case_dir/args" FM_TEST_CURL_STDIN="$case_dir/stdin" \
        run_status "$case_dir" --format json \
        'declared|gitea|https://gitea.example.com/a/b/issues/3') \
        || fail "multibyte enrichment failed"
    fi
    printf '%s' "$out" | jq -e '.[0].status == "ok" and (.[0].title | length) == 200' >/dev/null \
      || fail "$locale-locale multibyte title broke the JSON document or cap: $out"
    printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
      || fail "$locale-locale multibyte title was truncated into invalid UTF-8: $out"
  done
  pass "a long multibyte title is truncated without producing invalid UTF-8"
}

make_no_perl_toolbin() {  # <case-dir>
  local case_dir=$1 toolbin tool path
  toolbin="$case_dir/no-perl-bin"
  mkdir -p "$toolbin"
  for tool in awk bash chmod date dirname head mkdir mktemp mv rm sed sha256sum stat timeout tr uname; do
    path=$(command -v "$tool") || fail "no-perl fixture needs $tool"
    ln -s "$path" "$toolbin/$tool"
  done
  printf '%s\n' "$toolbin"
}

test_long_multibyte_title_is_capped_without_perl() {
  local case_dir out long toolbin
  command -v jq >/dev/null 2>&1 || { pass "no-perl multibyte truncation (skipped: jq absent)"; return; }
  case_dir=$(status_case gh-multibyte-no-perl)
  long=$(printf '測%.0s' {1..300})
  fake_gh_axi_issue "$case_dir" open "$long"
  toolbin=$(make_no_perl_toolbin "$case_dir")
  out=$(LC_ALL=C PATH="$case_dir/fakebin:$toolbin" run_status "$case_dir" --format json \
    'declared|github|https://github.com/x/y/issues/9') \
    || fail "no-perl multibyte enrichment failed"
  printf '%s' "$out" | jq -e '.[0].status == "ok" and (.[0].title | length) == 200' >/dev/null \
    || fail "no-perl multibyte title broke the JSON document or cap: $out"
  printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
    || fail "no-perl multibyte title produced invalid UTF-8: $out"
  pass "a long multibyte title remains capped and valid without Perl"
}

test_status_caches_and_rate_limits() {
  local case_dir out first second
  case_dir=$(status_case cache)
  fake_gh_axi_issue "$case_dir" open 'Cached title'
  first=$(FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9') || fail "first lookup failed"
  assert_contains "$first" 'Cached title' "first lookup did not enrich"

  # Break the adapter, then prove the cached answer is served instead of a live
  # call: a dashboard refresh must not reach the forge again.
  fake_gh_axi_failing "$case_dir"
  second=$(FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9') || fail "second lookup failed"
  assert_contains "$second" 'Cached title' "the cached result was not reused within its TTL"

  # --refresh must bypass the cache and therefore see the broken adapter.
  out=$(FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" --refresh \
    'declared|github|https://github.com/x/y/issues/9') || fail "refresh lookup failed"
  assert_contains "$out" 'unavailable' "--refresh served the cache instead of a live lookup"

  # An expired TTL must go live again.
  case_dir=$(status_case ttl)
  fake_gh_axi_issue "$case_dir" open 'Fresh title'
  FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9' >/dev/null || fail "ttl seed failed"
  fake_gh_axi_issue "$case_dir" closed 'Newer title'
  out=$(FM_ISSUE_STATUS_TTL=0 FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9') || fail "expired-TTL lookup failed"
  assert_contains "$out" 'Newer title' "an expired cache entry was still served"
  pass "status enrichment reuses a cached answer, honours --refresh, and expires it"
}

# An unavailable entry has an empty state. A cache record delimited by IFS
# whitespace collapses that empty field on read, which shifts the reason into
# the state column and leaves the reason column empty. Asserting only that the
# reason text appears SOMEWHERE passes against that bug, because the text is
# still on the line - just in the wrong field. So this pins the field layout:
# column 3 must be the no-state placeholder and column 4 must carry the reason.
field() {  # <line> <n>
  printf '%s' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

test_cached_unavailable_entry_keeps_its_reason() {
  local case_dir first second
  case_dir=$(status_case cache-unavailable)
  fake_gh_axi_failing "$case_dir"
  first=$(FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9') || fail "first lookup failed"
  [ "$(field "$first" 2)" = unavailable ] || fail "live failure did not report unavailable: $first"
  case "$(field "$first" 4)" in
    *'GitHub lookup failed'*) ;;
    *) fail "the live failure put no reason in the reason column: $first" ;;
  esac

  second=$(FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9') || fail "cached lookup failed"
  [ "$(printf '%s\n' "$second" | wc -l)" -eq 1 ] \
    || fail "the cached entry did not round-trip as one record: $second"
  [ "$(field "$second" 1)" = 'https://github.com/x/y/issues/9' ] \
    || fail "the cached entry lost its link: $second"
  [ "$(field "$second" 2)" = unavailable ] || fail "the cached entry lost its status: $second"
  [ "$(field "$second" 3)" = '-' ] \
    || fail "the cached entry put something other than the no-state placeholder in the state column: $second"
  case "$(field "$second" 4)" in
    *'GitHub lookup failed'*) ;;
    *) fail "a cached unavailable entry lost the reason from its reason column: $second" ;;
  esac
  pass "a cached unavailable entry keeps its reason in the reason column"
}

# With no cached answer and a host contacted moments ago, the reference must
# report that it was throttled rather than hammering the forge.
test_status_throttles_bursts_per_host() {
  local case_dir out
  case_dir=$(status_case throttle)
  fake_gh_axi_issue "$case_dir" open 'Burst title'
  out=$(FM_ISSUE_STATUS_MIN_INTERVAL=3600 run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/1' \
    'declared|github|https://github.com/x/y/issues/2') || fail "throttled run failed"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ] || fail "throttling dropped a reference: $out"
  printf '%s\n' "$out" | tail -n 1 | grep -q 'throttled' \
    || fail "a burst to one host was not throttled: $out"
  printf '%s\n' "$out" | tail -n 1 | grep -q 'https://github.com/x/y/issues/2' \
    || fail "a throttled reference lost its plain link: $out"
  pass "status enrichment spaces live lookups per host and still returns every link"
}

# The cache, not any cross-process lock, is what keeps a dashboard off a forge.
# Per-host spacing is best-effort and two concurrent processes may each go live
# once, so this is the assertion that actually covers the accepted criterion:
# however many times a board refreshes inside the TTL, the forge is asked once.
test_repeated_calls_within_ttl_make_no_live_lookup() {
  local case_dir calls out i=0
  case_dir=$(status_case ttl-cache)
  fake_gh_axi_issue "$case_dir" open 'Cached within TTL'
  calls="$case_dir/gh-calls"
  : > "$calls"
  while [ "$i" -lt 6 ]; do
    out=$(FM_TEST_GH_CALLS="$calls" FM_ISSUE_STATUS_MIN_INTERVAL=0 run_status "$case_dir" \
      'declared|github|https://github.com/x/y/issues/9') || fail "refresh $i failed"
    assert_contains "$out" 'Cached within TTL' "refresh $i lost the enriched title"
    i=$((i + 1))
  done
  [ "$(wc -l < "$calls")" -eq 1 ] \
    || fail "6 refreshes inside the TTL made $(wc -l < "$calls") live lookups"
  pass "repeated refreshes inside the TTL are served from the cache with one live lookup"
}

test_task_with_no_work_items_still_emits_a_json_document() {
  local case_dir out
  case_dir=$(status_case no-work-items)
  printf 'project=demo\nmode=no-mistakes\n' > "$case_dir/state/t-none.meta"
  out=$(run_status "$case_dir" --format json --task t-none) \
    || fail "a task with no work items must succeed in json mode"
  [ "$out" = '[]' ] \
    || fail "a task with no work items did not emit the empty array: $out"
  out=$(run_status "$case_dir" --task t-none) \
    || fail "a task with no work items must succeed in tsv mode"
  [ -z "$out" ] || fail "tsv for a task with no work items emitted output: $out"
  # A task whose metadata does not exist at all is the same first-class case.
  out=$(run_status "$case_dir" --format json --task t-absent) \
    || fail "a task with no metadata must succeed in json mode"
  [ "$out" = '[]' ] \
    || fail "a task with no metadata did not emit the empty array: $out"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -e 'length == 0' >/dev/null \
      || fail "the empty work-item document did not parse as an empty array: $out"
  fi
  pass "a task with no work items still emits a parseable json document"
}

test_unusable_cache_refuses_live_status_lookup() {
  local case_dir out
  case_dir=$(status_case unusable-cache)
  ln -s "$case_dir/not-a-directory" "$case_dir/state/issue-status"
  fake_gh_axi_issue "$case_dir" open 'Live call escaped limiter'
  out=$(FM_TEST_GH_CALLS="$case_dir/gh-calls" run_status "$case_dir" \
    'declared|github|https://github.com/x/y/issues/9') \
    || fail "unusable-cache status degradation failed"
  assert_contains "$out" 'https://github.com/x/y/issues/9' \
    "unusable-cache degradation lost the canonical link"
  assert_contains "$out" 'cache/rate limiter is unavailable' \
    "unusable-cache degradation did not name the limiter failure"
  assert_absent "$case_dir/gh-calls" \
    "an unusable cache authorized a live forge lookup"
  pass "an unusable status cache refuses live lookups with a visible reason"
}

test_malformed_record_cannot_forge_output_structure() {
  local case_dir record tsv json
  case_dir=$(status_case hostile-record)
  record=$'bad\tfield\nnext'
  tsv=$(run_status "$case_dir" "$record") || fail "hostile malformed TSV record failed"
  [ "$(printf '%s\n' "$tsv" | wc -l)" -eq 1 ] \
    || fail "a malformed record forged extra TSV lines: $tsv"
  [ "$(printf '%s' "$tsv" | tr -cd '\t' | wc -c)" -eq 3 ] \
    || fail "a malformed record forged extra TSV columns: $tsv"
  json=$(run_status "$case_dir" --format json "$record") \
    || fail "hostile malformed JSON record failed"
  printf '%s' "$json" | jq -e \
    'length == 1 and .[0].status == "unavailable" and .[0].reason == "malformed work-item record"' \
    >/dev/null || fail "a malformed record broke JSON output: $json"
  pass "a malformed record cannot forge TSV or JSON structure"
}

# --- credential contract ----------------------------------------------------

test_forge_token_is_used_without_reaching_the_process_arguments() {
  local case_dir out
  command -v jq >/dev/null 2>&1 || { pass "gitea credential handling (skipped: jq absent)"; return; }
  case_dir=$(status_case token-ok)
  mkdir -p "$case_dir/config/forge-tokens"
  printf 'super-secret-token\n' > "$case_dir/config/forge-tokens/gitea.example.com"
  chmod 600 "$case_dir/config/forge-tokens/gitea.example.com"
  fake_curl "$case_dir" 200 '{"state":"open","title":"Tokened"}'
  out=$(FM_TEST_CURL_ARGS="$case_dir/args" FM_TEST_CURL_STDIN="$case_dir/stdin" \
    run_status "$case_dir" 'declared|gitea|https://gitea.example.com/a/b/issues/3') \
    || fail "authenticated gitea lookup failed"
  assert_contains "$out" 'Tokened' "the authenticated lookup did not enrich"
  assert_no_grep 'super-secret-token' "$case_dir/args" \
    "the forge token appeared in curl's process arguments"
  assert_grep 'super-secret-token' "$case_dir/stdin" \
    "the forge token did not reach curl through its stdin config"
  assert_not_contains "$out" 'super-secret-token' "the forge token leaked into output"
  grep -rqF 'super-secret-token' "$case_dir/state" 2>/dev/null \
    && fail "the forge token was written into cached state"
  pass "a forge token reaches curl through stdin, never argv, output, or the cache"
}

test_loose_token_permissions_are_refused() {
  local case_dir out
  case_dir=$(status_case token-loose)
  mkdir -p "$case_dir/config/forge-tokens"
  printf 'loose-token\n' > "$case_dir/config/forge-tokens/gitea.example.com"
  chmod 644 "$case_dir/config/forge-tokens/gitea.example.com"
  fake_curl "$case_dir" 200 '{"state":"open","title":"Should not happen"}'
  out=$(FM_TEST_CURL_ARGS="$case_dir/args" FM_TEST_CURL_STDIN="$case_dir/stdin" \
    run_status "$case_dir" 'declared|gitea|https://gitea.example.com/a/b/issues/3') \
    || fail "a loose token must not fail the command"
  assert_contains "$out" 'mode 0600' "a world-readable token was not refused with a reason"
  assert_not_contains "$out" 'Should not happen' "a world-readable token was used anyway"
  pass "a forge token stored with loose permissions is refused rather than used"
}

# The credential must never travel to a secondmate home. The inheritance
# allowlist in bin/fm-config-inherit-lib.sh is the single owner of what does.
test_forge_tokens_are_not_inheritable_config() {
  local items
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  items=$(fm_config_inherit_items)
  assert_not_contains "$items" 'forge-tokens' \
    "forge credentials entered the inherited-config allowlist"
  pass "forge credentials are absent from the inherited-config allowlist"
}

test_config_directory_is_untracked() {
  git -C "$ROOT" check-ignore -q config/forge-tokens/example.com \
    || fail "config/forge-tokens is not gitignored, so a credential could be committed"
  pass "the forge credential path is gitignored"
}

test_github_project_resolves_bare_number
test_gitea_project_resolves_on_its_own_host
test_declared_tracker_beats_the_clone_directory_name
test_git_remote_never_decides_the_tracker
test_undeclared_tracker_refuses_bare_reference
test_explicit_none_refuses_with_its_own_reason
test_malformed_declaration_is_reported_not_treated_as_absent
test_duplicate_tracker_declaration_is_refused
test_show_tracker_refuses_a_format_it_cannot_honour
test_malformed_references_are_refused
test_qualified_reference_forms_resolve
test_ambiguous_self_hosted_url_is_refused_not_guessed
test_owner_repo_form_is_refused_for_nested_gitlab
test_multiple_and_zero_references
test_one_bad_reference_fails_the_whole_set
test_json_output_carries_the_manifest_fields
test_show_tracker_reports_declaration_and_absence
test_tracker_token_does_not_disturb_delivery_posture
test_brief_records_resolved_work_items
test_brief_refuses_unresolved_work_items
test_spawn_records_resolved_work_items_in_metadata
test_spawn_upgrades_a_legacy_issue_marker_through_the_declared_tracker
test_spawn_warns_when_a_legacy_marker_has_no_declared_tracker
test_spawn_refuses_a_malformed_work_item_marker
test_github_status_enrichment
test_self_hosted_github_status_is_reported_without_a_live_call
test_status_degrades_cleanly_on_every_failure_mode
test_github_status_lookup_is_bounded
test_gitea_status_enrichment_and_title_sanitizing
test_long_multibyte_title_stays_valid_utf8
test_long_multibyte_title_is_capped_without_perl
test_status_caches_and_rate_limits
test_cached_unavailable_entry_keeps_its_reason
test_status_throttles_bursts_per_host
test_repeated_calls_within_ttl_make_no_live_lookup
test_task_with_no_work_items_still_emits_a_json_document
test_unusable_cache_refuses_live_status_lookup
test_malformed_record_cannot_forge_output_structure
test_forge_token_is_used_without_reaching_the_process_arguments
test_loose_token_permissions_are_refused
test_forge_tokens_are_not_inheritable_config
test_config_directory_is_untracked
