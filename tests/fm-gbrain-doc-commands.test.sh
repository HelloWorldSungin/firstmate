#!/usr/bin/env bash
# Behavior tests for the operator command blocks docs/gbrain.md publishes.
#
# Those blocks are an executable contract rather than illustration: an operator
# pastes them into a shell and they initialize, reconfigure, back up, migrate,
# or wipe a real brain. For most of this page's life they carried the absolute
# paths of one deployment, so pasting them from any other home addressed a brain
# that home does not own - and when that deployment was deleted the blocks went
# on naming a tree that no longer existed while still looking correct. Stating
# in prose that a reader should substitute their own values did not stop that.
#
# So these cases run the blocks. Each one is lifted from the tracked document
# and executed against a synthetic Firstmate home, with the GBrain executable
# replaced by a stub that records the GBRAIN_HOME and argv it was handed. That
# substitution is the only edit: it makes the block offline and harmless without
# changing what it resolves. Every assertion is then on observable behavior -
# the environment the stub actually received, the exit status, and the files the
# block created - never on the document's wording.
#
# A block is selected by the command it invokes rather than by position, and a
# selection that does not match exactly one block fails loudly, so restructuring
# the page reports a clear failure instead of silently testing nothing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

DOC="$ROOT/docs/gbrain.md"
[ -f "$DOC" ] || fail "no docs/gbrain.md under $ROOT"

TMP_ROOT=$(fm_test_tmproot fm-gbrain-doc-commands)

# The backup block selects its durable source with `find ! -readable`, which is
# a GNU predicate. Where it is unavailable the block cannot run at all and the
# cases that exercise it would report a document defect that is not one.
HAVE_FIND_READABLE=yes
find "$TMP_ROOT" -maxdepth 0 ! -readable >/dev/null 2>&1 || HAVE_FIND_READABLE=no

# --- lifting the blocks -----------------------------------------------------

# Every fenced sh block in the document, separated by a form feed so a block's
# own blank lines survive.
doc_blocks() {
  awk '
    /^```sh$/ { grab = 1; next }
    /^```$/   { if (grab) { printf "\f"; grab = 0 } next }
    grab      { print }
  ' "$DOC"
}

# The one sh block that invokes <needle>. Exactly one must, because a case that
# silently matched none would pass over the behavior it exists to pin, and one
# that matched several would test whichever came first.
doc_block_invoking() {  # <needle>
  local needle=$1 blocks n
  blocks=$(doc_blocks)
  n=$(printf '%s' "$blocks" | awk -v RS='\f' -v n="$needle" 'index($0, n) { c++ } END { print c + 0 }')
  [ "$n" -eq 1 ] \
    || fail "docs/gbrain.md must publish exactly one sh block invoking '$needle', found $n"
  printf '%s' "$blocks" | awk -v RS='\f' -v n="$needle" 'index($0, n) { print; exit }'
}

# The block under "## Operating paths" that resolves this home's brain once for
# the blocks that read it. Selected by the section rather than by a command,
# because it invokes nothing.
doc_resolve_block() {
  local block
  block=$(awk '
    /^## Operating paths/ { in_section = 1; next }
    /^## /                { in_section = 0 }
    in_section && /^```sh$/ { grab = 1; next }
    /^```$/               { if (grab) exit }
    grab                  { print }
  ' "$DOC")
  [ -n "$block" ] || fail 'docs/gbrain.md publishes no resolve block under "## Operating paths"'
  printf '%s\n' "$block"
}

# --- fixtures ---------------------------------------------------------------

# A stub standing in for the pinned GBrain executable. It records the runtime
# directory and arguments each invocation received, which is what these cases
# read instead of the document's text. Its log sits beside it rather than in a
# variable, because the call site captures stdout and so runs this in a subshell
# whose assignments never reach the caller.
make_stub() {  # <name> -> path to the stub
  local dir="$TMP_ROOT/stub-$1"
  mkdir -p "$dir"
  : > "$dir/invocations"
  cat > "$dir/gbrain" <<STUB
#!/usr/bin/env bash
printf 'GBRAIN_HOME=%s argv=%s\n' "\${GBRAIN_HOME:-<unset>}" "\$*" >> "$dir/invocations"
STUB
  chmod 0755 "$dir/gbrain"
  printf '%s\n' "$dir/gbrain"
}

stub_log() {  # <stub>
  printf '%s\n' "$(dirname "$1")/invocations"
}

# A Firstmate home carrying an initialized brain. <shape> decides its durable
# document source: "capture" gives it an outbox and no archive, the shape a home
# fed by task-knowledge capture actually has; "archive" gives it a remote-less
# Git archive and no outbox; "bare" gives it neither; "uninitialized" leaves out
# the runtime and index a brain needs at all.
make_home() {  # <name> <shape> -> path to the home
  local home="$TMP_ROOT/home-$1" shape=$2
  mkdir -p "$home/config" "$home/data"
  if [ "$shape" != uninitialized ]; then
    mkdir -p "$home/data/gbrain/runtime/.gbrain" "$home/data/gbrain/pglite"
    printf 'index\n' > "$home/data/gbrain/pglite/index"
  fi
  case $shape in
    capture)
      mkdir -p "$home/data/gbrain-outbox"
      printf '{"id":"rec-1"}\n' > "$home/data/gbrain-outbox/rec-1.json"
      ;;
    archive)
      mkdir -p "$home/data/gbrain/archive"
      git -C "$home/data/gbrain/archive" init -q
      printf 'note\n' > "$home/data/gbrain/archive/note.md"
      git -C "$home/data/gbrain/archive" add -A
      git -C "$home/data/gbrain/archive" \
        -c user.email=test@example.invalid -c user.name=test commit -qm seed
      ;;
  esac
  printf '%s\n' "$home"
}

# A credential store in the shape the raw `think` block reads, so that block can
# run without touching the operator's real one.
make_fake_home_dir() {  # <name> -> path to use as HOME
  local dir="$TMP_ROOT/fakehome-$1"
  mkdir -p "$dir/.pi/agent"
  printf '{"minimax":{"key":"stub-key-not-a-credential"}}\n' > "$dir/.pi/agent/auth.json"
  chmod 0600 "$dir/.pi/agent/auth.json"
  printf '%s\n' "$dir"
}

# Run the given blocks in ONE shell, in order, the way an operator pastes them,
# from the code root the document tells them to stand in. The pinned executable
# is rewritten to the stub and nothing else is touched. Extra assignments in
# <preset> are exported first, which is how a stale value from an earlier shell
# is reproduced.
run_blocks() {  # <stub> <home> <fake-home> <preset-or-empty> <block>...
  local stub=$1 home=$2 fake_home=$3 preset=$4
  shift 4
  local script="$TMP_ROOT/pasted.$$.sh"
  : > "$script"
  local block
  for block in "$@"; do
    printf '%s\n' "$block" >> "$script"
  done
  # The one edit: the absolute executable the blocks invoke becomes the stub.
  # Matched generically so the document is free to move its installation.
  perl -pi -e 's{\S*/bin/gbrain\b}{'"$stub"'}g' "$script" 2>/dev/null \
    || fail "could not redirect the document's gbrain invocations to the stub"
  ( cd "$ROOT" \
      && env FM_HOME="$home" HOME="$fake_home" ${preset:+"$preset"} \
        bash "$script" ) 2>&1
}

# Every runtime directory and index path the stub was handed across a run.
stub_paths() {  # <stub>
  local log
  log=$(stub_log "$1")
  sed -e 's/.*GBRAIN_HOME=\([^ ]*\).*/\1/' "$log"
  grep -oE -- '--path [^ ]+' "$log" | awk '{ print $2 }' || true
}

stub_invocations() {  # <stub>
  local log
  log=$(stub_log "$1")
  [ -s "$log" ] && wc -l < "$log" | tr -d ' ' || printf '0\n'
}

# --- cases ------------------------------------------------------------------

test_reading_blocks_address_the_home_that_was_resolved() {
  local stub home fake out p brain
  stub=$(make_stub resolved)
  home=$(make_home resolved capture)
  fake=$(make_fake_home_dir resolved)
  brain="$home/data/gbrain"
  out=$(run_blocks "$stub" "$home" "$fake" '' \
    "$(doc_resolve_block)" \
    "$(doc_block_invoking 'gbrain init --pglite')" \
    "$(doc_block_invoking 'config set models.think')" \
    "$(doc_block_invoking 'gbrain import')" \
    "$(doc_block_invoking 'gbrain think')")
  [ "$(stub_invocations "$stub")" -gt 0 ] \
    || fail "the resolved blocks invoked no gbrain at all: $out"
  # Every runtime directory and index path handed to the executable has to sit
  # inside the brain the resolve block resolved. A block still carrying one
  # deployment's absolute path fails here whatever the prose around it says.
  while read -r p; do
    [ -n "$p" ] || continue
    case $p in
      "$brain"/*) ;;
      *) fail "a block addressed $p, outside the resolved brain $brain: $(cat "$(stub_log "$stub")")" ;;
    esac
  done <<< "$(stub_paths "$stub")"
  pass "the blocks that read the resolve block address the brain it resolved"
}

test_a_block_pasted_without_the_resolve_block_refuses() {
  local stub home fake needle out rc
  for needle in 'gbrain init --pglite' 'config set models.think' 'gbrain import' 'gbrain think'; do
    stub=$(make_stub "unresolved-${needle// /-}")
    home=$(make_home unresolved capture)
    fake=$(make_fake_home_dir unresolved)
    out=$(run_blocks "$stub" "$home" "$fake" '' "$(doc_block_invoking "$needle")") && rc=0 || rc=$?
    [ "$rc" -ne 0 ] \
      || fail "the block invoking '$needle' exited 0 with nothing resolved: $out"
    [ "$(stub_invocations "$stub")" -eq 0 ] \
      || fail "the block invoking '$needle' reached gbrain with nothing resolved: $(cat "$(stub_log "$stub")")"
    assert_contains "$out" 'Operating paths' \
      "the refusal for '$needle' must name what the operator skipped"
  done
  pass "a block pasted with nothing resolved refuses before it reaches gbrain"
}

test_a_wiping_block_discards_a_stale_resolved_value() {
  local stub home fake out p brain
  stub=$(make_stub stale)
  home=$(make_home stale capture)
  fake=$(make_fake_home_dir stale)
  brain="$home/data/gbrain"
  # A value that is set and plausible but points at another brain entirely -
  # the failure a guard alone cannot catch, because a guard only checks that a
  # variable is set.
  out=$(run_blocks "$stub" "$home" "$fake" "gbrain_home=$TMP_ROOT/other-brain/runtime" \
    "$(doc_block_invoking 'reinit-pglite')")
  [ "$(stub_invocations "$stub")" -gt 0 ] || fail "the reinit block invoked no gbrain: $out"
  while read -r p; do
    [ -n "$p" ] || continue
    case $p in
      "$brain"/*) ;;
      *) fail "the reinit block inherited $p instead of re-resolving: $(cat "$(stub_log "$stub")")" ;;
    esac
  done <<< "$(stub_paths "$stub")"
  assert_contains "$out" "$home" \
    "the reinit block must name the home it is about to wipe"
  pass "a block that wipes a brain re-resolves rather than inheriting a stale value"
}

test_a_wiping_block_refuses_a_home_with_no_initialized_brain() {
  local stub home fake out rc
  stub=$(make_stub uninitialized)
  home=$(make_home uninitialized uninitialized)
  fake=$(make_fake_home_dir uninitialized)
  out=$(run_blocks "$stub" "$home" "$fake" '' "$(doc_block_invoking 'reinit-pglite')") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "the reinit block exited 0 against an uninitialized home: $out"
  [ "$(stub_invocations "$stub")" -eq 0 ] \
    || fail "the reinit block reached gbrain against an uninitialized home: $(cat "$(stub_log "$stub")")"
  assert_contains "$out" "$home" "the refusal must name the home that failed to resolve"
  pass "a block that wipes a brain refuses a home carrying no initialized brain"
}

test_the_migration_block_refuses_a_home_with_no_initialized_brain() {
  local stub home fake block guard out rc
  stub=$(make_stub migrate)
  home=$(make_home migrate uninitialized)
  fake=$(make_fake_home_dir migrate)
  # Only the guard runs. The lines past it fetch and check out a release tag the
  # document leaves as a <verified-tag> placeholder for the operator to choose,
  # so the block cannot be executed further than the decision it guards.
  block=$(doc_block_invoking 'apply-migrations')
  guard=$(printf '%s\n' "$block" | sed -n '1,/^fi$/p')
  [ -n "$guard" ] || fail "the migration block publishes no guard to run"
  out=$(run_blocks "$stub" "$home" "$fake" '' "$guard") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "the migration guard exited 0 against an uninitialized home: $out"
  assert_contains "$out" "$home" "the refusal must name the home whose brain would be migrated"
  pass "the migration guard refuses a home carrying no initialized brain runtime"
}

test_the_backup_block_uses_the_capture_outbox_when_no_archive_exists() {
  local stub home fake out rc dest
  [ "$HAVE_FIND_READABLE" = yes ] || { echo "skip: find has no ! -readable"; return 0; }
  stub=$(make_stub backup-capture)
  home=$(make_home backup-capture capture)
  fake=$(make_fake_home_dir backup-capture)
  # This home has no archive/ at all, which is the shape the document now says a
  # capture-fed home has. If its rebuild path genuinely depended on an archive
  # the block would have nothing to copy and would refuse.
  assert_absent "$home/data/gbrain/archive" "the capture-fed fixture must carry no archive"
  out=$(run_blocks "$stub" "$home" "$fake" '' "$(doc_block_invoking 'backups')") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "the backup block refused a capture-fed home: $out"
  dest=$(printf '%s\n' "$out" | tail -1)
  assert_present "$dest/gbrain-outbox/rec-1.json" \
    "the backup must carry the outbox record it chose as the durable source"
  assert_present "$dest/pglite/index" "the backup must carry the index"
  assert_present "$dest/.gbrain" "the backup must carry the runtime configuration"
  pass "the backup block rebuilds a capture-fed home from its outbox, with no archive"
}

test_the_backup_block_falls_back_to_a_git_archive() {
  local stub home fake out rc dest
  [ "$HAVE_FIND_READABLE" = yes ] || { echo "skip: find has no ! -readable"; return 0; }
  stub=$(make_stub backup-archive)
  home=$(make_home backup-archive archive)
  fake=$(make_fake_home_dir backup-archive)
  out=$(run_blocks "$stub" "$home" "$fake" '' "$(doc_block_invoking 'backups')") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "the backup block refused an archive-fed home: $out"
  dest=$(printf '%s\n' "$out" | tail -1)
  assert_present "$dest/archive/note.md" \
    "an archive-fed home's backup must carry the archive it chose"
  pass "the backup block falls back to a Git archive when a home has one"
}

test_the_backup_block_refuses_when_no_durable_source_exists() {
  local stub home fake out rc
  [ "$HAVE_FIND_READABLE" = yes ] || { echo "skip: find has no ! -readable"; return 0; }
  stub=$(make_stub backup-bare)
  home=$(make_home backup-bare bare)
  fake=$(make_fake_home_dir backup-bare)
  out=$(run_blocks "$stub" "$home" "$fake" '' "$(doc_block_invoking 'backups')") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "the backup block reported success with nothing durable to copy: $out"
  assert_absent "$home/data/gbrain/backups" \
    "a refused backup must leave no half-written backup directory"
  pass "the backup block refuses when neither an outbox nor an archive exists"
}

test_resolved_paths_carry_no_absolute_brain_location() {
  local stub home fake out p home_paths
  stub=$(make_stub portable)
  # A second home, so a block that had been written from one deployment cannot
  # accidentally look right. Nothing about this home resembles the host the
  # document was written on.
  home=$(make_home portable-elsewhere capture)
  fake=$(make_fake_home_dir portable)
  out=$(run_blocks "$stub" "$home" "$fake" '' \
    "$(doc_resolve_block)" "$(doc_block_invoking 'gbrain init --pglite')")
  home_paths=$(stub_paths "$stub" | grep -c . || true)
  [ "$home_paths" -gt 0 ] || fail "the init block resolved nothing to address: $out"
  while read -r p; do
    [ -n "$p" ] || continue
    case $p in
      "$home"/*) ;;
      *) fail "the init block addressed $p rather than the caller's home $home" ;;
    esac
  done <<< "$(stub_paths "$stub")"
  pass "an arbitrary home's own brain is what the resolved blocks address"
}

test_reading_blocks_address_the_home_that_was_resolved
test_a_block_pasted_without_the_resolve_block_refuses
test_a_wiping_block_discards_a_stale_resolved_value
test_a_wiping_block_refuses_a_home_with_no_initialized_brain
test_the_migration_block_refuses_a_home_with_no_initialized_brain
test_the_backup_block_uses_the_capture_outbox_when_no_archive_exists
test_the_backup_block_falls_back_to_a_git_archive
test_the_backup_block_refuses_when_no_durable_source_exists
test_resolved_paths_carry_no_absolute_brain_location

fm_test_every_defined_test_ran

printf '\nall fm-gbrain-doc-commands tests passed\n'
