#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  assert_contains "$help" "--issue is the older same-repository GitHub form" \
    "fm-brief.sh --help omitted the issue argument"
  assert_contains "$help" "--work-item records a resolved work item" \
    "fm-brief.sh --help omitted the work-item argument"
  assert_contains "$help" "--continue-branch <name> is how a ship or design task continues" \
    "fm-brief.sh --help omitted the continue-branch argument"
  assert_contains "$help" "a branch held by another worktree blocks checkout, not push" \
    "fm-brief.sh --help omitted the checkout-versus-push rule"
  pass "fm-brief.sh: --help renders the complete header"
}

test_design_help_authorizes_no_implementation() {
  local help design_modes
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Design modes deliver only the ADR" \
    "fm-brief.sh --help omitted the design delivery contract"
  design_modes=$(printf '%s\n' "$help" | awk '
    /^Design modes deliver only the ADR:/ { capture=1; next }
    capture && /^[A-Z]/ { exit }
    capture { print }
  ')
  assert_not_contains "$design_modes" "implement" \
    "fm-brief.sh --help authorizes implementation for design modes"
  pass "fm-brief.sh: --help documents ADR-only design delivery"
}

test_issue_traceability_is_strictly_opt_in() {
  local home plain traced
  home="$TMP_ROOT/issue-traceability-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" plain-task sample --mode no-mistakes >/dev/null 2>&1
  plain="$home/data/plain-task/brief.md"
  assert_no_grep 'firstmate-task-issue=' "$plain" \
    "ordinary brief unexpectedly recorded an issue"
  assert_no_grep '# GitHub issue traceability' "$plain" \
    "ordinary brief unexpectedly gained the issue contract"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" traced-task sample --mode no-mistakes --issue 37 >/dev/null 2>&1
  traced="$home/data/traced-task/brief.md"
  assert_grep '<!-- firstmate-task-issue=37 -->' "$traced" \
    "issue brief did not carry its explicit machine-readable issue identity"
  assert_grep 'comment on GitHub issue #37 with a substantive summary of what you found and what you actually changed' "$traced" \
    "issue brief did not require a substantive issue comment"
  assert_grep 'A bare "done" comment does not satisfy this contract' "$traced" \
    "issue brief did not reject an empty completion comment"
  # shellcheck disable=SC2016 # Literal backticks are part of the generated Markdown.
  assert_grep 'Put `Closes #37` in the PR body' "$traced" \
    "issue brief did not require the atomic closing keyword"
  assert_grep 'Amend the existing PR body rather than replacing it' "$traced" \
    "issue brief let a worker clobber the pipeline-owned PR body"
  pass "fm-brief.sh: issue traceability appears only for an explicitly recorded issue"
}

test_issue_argument_validation_and_delivery_mode_guards() {
  local home rc name value expected
  home="$TMP_ROOT/issue-validation-home"
  write_registry "$home"

  for name in zero nonnumeric missing; do
    case "$name" in
      zero) value=0; expected='requires a positive GitHub issue number' ;;
      nonnumeric) value=abc; expected='requires a positive GitHub issue number' ;;
      missing) value=; expected='requires a value' ;;
    esac
    if [ "$name" = missing ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "issue-$name" sample --mode no-mistakes --issue \
        > "$home/$name.stdout" 2> "$home/$name.stderr"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "issue-$name" sample --mode no-mistakes --issue "$value" \
        > "$home/$name.stdout" 2> "$home/$name.stderr"
    fi
    rc=$?
    expect_code 1 "$rc" "--issue $name should fail"
    assert_grep "$expected" "$home/$name.stderr" \
      "--issue $name did not explain its invalid value"
    assert_absent "$home/data/issue-$name/brief.md" \
      "--issue $name wrote a brief despite the refusal"
  done

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" issue-scout sample --issue 8 --scout \
    > "$home/scout.stdout" 2> "$home/scout.stderr"
  rc=$?
  expect_code 1 "$rc" "--issue should reject scout briefs"
  assert_grep 'applies only to ship or design briefs' "$home/scout.stderr" \
    "--issue scout refusal did not explain the task-kind guard"
  assert_absent "$home/data/issue-scout/brief.md" \
    "--issue scout refusal wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" issue-local local-proj --mode local-only --issue 9 \
    > "$home/local.stdout" 2> "$home/local.stderr"
  rc=$?
  expect_code 1 "$rc" "--issue should reject local-only delivery"
  assert_grep 'requires a PR-based delivery mode' "$home/local.stderr" \
    "--issue local-only refusal did not explain the delivery-mode guard"
  assert_absent "$home/data/issue-local/brief.md" \
    "--issue local-only refusal wrote a brief"

  pass "fm-brief.sh: --issue accepts only positive numbers on PR-based ship briefs"
}

brief_fingerprint() {
  local brief=$1 data=$2 id=$3 hash bytes
  hash=$(
    FM_GOLDEN_ROOT="$ROOT" FM_GOLDEN_DATA="$data" perl -pe \
      's/\Q$ENV{FM_GOLDEN_ROOT}\E/<FM_ROOT>/g; s/\Q$ENV{FM_GOLDEN_DATA}\E/<FM_DATA>/g' \
      "$brief" | shasum -a 256 | awk '{print $1}'
  )
  bytes=$(
    FM_GOLDEN_ROOT="$ROOT" FM_GOLDEN_DATA="$data" perl -pe \
      's/\Q$ENV{FM_GOLDEN_ROOT}\E/<FM_ROOT>/g; s/\Q$ENV{FM_GOLDEN_DATA}\E/<FM_DATA>/g' \
      "$brief" | wc -c | tr -d ' '
  )
  printf '%s %s %s\n' "$hash" "$bytes" "$id"
}

test_no_issue_briefs_match_exact_goldens() {
  local home actual id
  home="$TMP_ROOT/no-issue-golden-home"
  actual="$TMP_ROOT/no-issue-golden.actual"
  write_registry "$home"

  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state \
    "$ROOT/bin/fm-brief.sh" golden-nm no-registry-proj --mode no-mistakes >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state \
    "$ROOT/bin/fm-brief.sh" golden-direct direct-proj --mode direct-PR >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state \
    "$ROOT/bin/fm-brief.sh" golden-local local-proj --mode local-only >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state \
    "$ROOT/bin/fm-brief.sh" golden-ship-herdr no-registry-proj --mode no-mistakes --herdr-lab >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state \
    "$ROOT/bin/fm-brief.sh" golden-scout sample --scout >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state \
    "$ROOT/bin/fm-brief.sh" golden-scout-herdr sample --scout --herdr-lab >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state FM_SECONDMATE_CHARTER='{TASK}' \
    "$ROOT/bin/fm-brief.sh" golden-secondmate --secondmate alpha beta >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE=/golden/state FM_SECONDMATE_CHARTER='{TASK}' \
    "$ROOT/bin/fm-brief.sh" golden-secondmate-empty --secondmate --no-projects >/dev/null 2>&1

  : > "$actual"
  for id in golden-nm golden-direct golden-local golden-ship-herdr \
    golden-scout golden-scout-herdr golden-secondmate golden-secondmate-empty; do
    brief_fingerprint "$home/data/$id/brief.md" "$home/data" "$id" >> "$actual"
  done
  if ! cmp "$ROOT/tests/fixtures/fm-brief-no-issue.sha256" "$actual"; then
    diff -u "$ROOT/tests/fixtures/fm-brief-no-issue.sha256" "$actual" >&2 || true
    fail "no-issue brief bytes drifted from the recorded no-issue goldens"
  fi
  pass "fm-brief.sh: no-issue brief variants remain byte-identical"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    grep -qx "<!-- firstmate-task-branch=fm/$id -->" "$brief" \
      || fail "$id: brief did not record its exact machine-readable task branch"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    grep -qx '1. First action: create your branch: `git checkout -b fm/'"$id"'`' "$brief" \
      || fail "$id: ordinary Setup first action drifted from git checkout -b fm/<task-id>"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship and design briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'append `blocked: implemented and committed, ready to validate`' "$brief" \
    "explicit no-mistakes brief did not render the blocked: validation handoff"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's approval authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship or design briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship or design briefs
continue-branch on a scout brief|brief-refused-b5 some-proj --scout --continue-branch other|--continue-branch applies only to ship or design briefs
continue-branch on a secondmate charter|brief-refused-b6 --secondmate --no-projects --continue-branch other|--continue-branch applies only to ship or design briefs
ROWS
  pass "fm-brief.sh: --yolo, scout/secondmate --mode, and --continue-branch on non-tracked-output kinds are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Three status-reporting gaps observed across five crewmates in one session:
# (1) no-mistakes workers appended done: after their own tests passed, before the
# pipeline ran; (2) workers parked on a backgrounded pipeline call left a spent
# needs-decision: line standing, so supervision read them as awaiting an answered
# decision while the quiet pane raised stale alarms; (3) a trailing keyed
# resolved: line leaves no state verb at all, so a healthy worker reads as
# unknown and becomes indistinguishable from a dead one. All three are scaffold
# defects, so the generated contract - not steering - has to close them.
test_status_protocol_closes_reporting_gaps() {
  local home id brief scout
  home="$TMP_ROOT/status-gaps-home"
  mkdir -p "$home/data"
  id="brief-status-gaps-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # Gap 1: done: under no-mistakes means PR open with checks green, never a
  # clean local commit, and the interim handoff must not be spelled done:.
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'ships **no-mistakes**: `done:` means the PR is open with its checks green' "$brief" \
    "no-mistakes DOD must define done: as PR open with checks green"
  assert_grep 'A clean local commit is NOT done' "$brief" \
    "no-mistakes DOD must reject a clean local commit as done"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'exactly one `done:` line and it is the last one, `done: PR {url} checks green`' "$brief" \
    "no-mistakes DOD must pin the single terminal done: line"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_no_grep 'append `done: {summary}`' "$brief" \
    "no-mistakes DOD still tells the worker to report done before the pipeline runs"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'append `blocked: implemented and committed, ready to validate`' "$brief" \
    "no-mistakes DOD must use blocked: for the validation-trigger handoff"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_no_grep 'append `paused: implemented and committed, ready to validate`' "$brief" \
    "no-mistakes DOD still teaches paused: for the validation-trigger handoff"

  # Gap 2: park-and-resume around a backgrounded pipeline call.
  assert_grep 'Park-and-resume pairing: whenever you background a pipeline call and go idle' "$brief" \
    "status protocol lost the park-and-resume rule"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`paused:` BEFORE going idle and `working:` as soon as it returns' "$brief" \
    "status protocol must pair paused: while parked with working: on return"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`needs-decision:` stays standing and firstmate reads you as still waiting' "$brief" \
    "status protocol must explain the spent needs-decision: misreading"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'While you sit parked on a backgrounded `axi run` or `axi respond` call' "$brief" \
    "no-mistakes DOD lost the park-and-resume reminder at the pipeline gate"

  # Gap 3: resolved: carries no state, so it must never be the last line.
  # This is the highest-value gap: it makes a healthy worker invisible.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id-scout" some-proj --scout >/dev/null 2>&1
  scout="$home/data/$id-scout/brief.md"
  assert_present "$scout" "scout brief was not scaffolded"
  local generated
  for generated in "$brief" "$scout"; do
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep '`resolved:` carries NO state, so it must never be your last line' "$generated" \
      "$generated: contract must forbid a trailing stateless resolved: line"
    assert_grep 'append the next state line' "$generated" \
      "$generated: contract must require a state line after resolved:"
    assert_grep 'invisible to firstmate and indistinguishable from a dead worker' "$generated" \
      "$generated: contract must state the invisibility consequence of a trailing resolved:"
  done
  pass "fm-brief.sh: status protocol closes the done:/park/resolved: reporting gaps"
}

# Issue #110: the generated brief must teach blocked: for waits that need firstmate,
# with a worked example close enough to the no-mistakes validation handoff that a
# worker can choose the right verb without reading AGENTS.md. This fails if the DOD
# reverts to paused: for that handoff, if the status protocol drops the blocked:
# validation-trigger example, if it stops distinguishing self-clearing waits from
# firstmate-action waits, or if it removes the external-wait paused: example.
test_status_protocol_teaches_blocked_for_firstmate_waits() {
  local home id brief
  home="$TMP_ROOT/blocked-verb-home"
  mkdir -p "$home/data"
  id="brief-blocked-verb-e1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # DOD handoff must name blocked:, not the pause verb.
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'append `blocked: implemented and committed, ready to validate`' "$brief" \
    "no-mistakes DOD must prescribe blocked: for the validation handoff"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_no_grep 'append `paused: implemented and committed, ready to validate`' "$brief" \
    "no-mistakes DOD still prescribes paused: for the validation handoff"
  assert_grep 'firstmate must trigger validation' "$brief" \
    "no-mistakes DOD must explain why the validation handoff is blocked:, not paused:"

  # Status protocol must carry paired worked examples and the discriminator rule.
  assert_grep 'Choose the verb by what clears the wait, not by whether you are idle.' "$brief" \
    "status protocol lost the discriminator rule"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`paused:` is for a bounded external wait expected to clear on its own' "$brief" \
    "status protocol lost the paused: self-clearing-wait definition"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`blocked:` is when firstmate must act before you can continue' "$brief" \
    "status protocol lost the blocked: firstmate-action definition"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`blocked: implemented and committed, ready to validate` when implementation is done and you' "$brief" \
    "status protocol lost the blocked: validation-trigger worked example"
  assert_grep "need firstmate's validation trigger" "$brief" \
    "status protocol lost the validation-trigger continuation"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`paused: rate limit resets at 06:00 UTC`' "$brief" \
    "status protocol lost the paused: external-wait worked example"
  assert_grep 'Wrong-verb cost:' "$brief" \
    "status protocol lost the wrong-verb cost asymmetry note"
  assert_grep 'can idle you for an hour under away mode' "$brief" \
    "status protocol must state the away-mode idle cost of misusing the pause verb"

  # Park-and-resume for backgrounded pipeline calls stays on the pause verb.
  assert_grep 'Park-and-resume pairing: whenever you background a pipeline call and go idle' "$brief" \
    "status protocol lost the park-and-resume rule"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`paused:` BEFORE going idle and `working:` as soon as it returns' "$brief" \
    "status protocol must keep paused:/working: park-and-resume pairing"

  pass "fm-brief.sh: status protocol teaches blocked: for firstmate-action waits"
}

# Issue #141: a worker waited with `pgrep -f 'shellcheck --norc'` and the wait
# matched its own command line, spinning for ~49 minutes. The generated brief
# must spell the trap once, in the shared ship/design rule that already teaches
# backgrounding, and must not copy it into scout, secondmate, or the no-mistakes
# DOD that already points at rule 4.
# This fails if that rule drops either line, if a second copy appears in a
# variant that already carries it, if a ship or design mode diverges from the
# shared Rules template, or if scout/secondmate start carrying a copy.
test_status_protocol_warns_against_self_matching_pgrep() {
  local home brief count plugin registry
  home="$TMP_ROOT/pgrep-warn-home"
  plugin="$TMP_ROOT/pgrep-warn-plugin"
  registry="$TMP_ROOT/pgrep-warn-registry.json"
  mkdir -p "$home/data" "$plugin/skills/productivity/grilling" \
    "$plugin/skills/engineering/domain-modeling"
  printf 'grilling\n' > "$plugin/skills/productivity/grilling/SKILL.md"
  printf 'domain modeling\n' > "$plugin/skills/engineering/domain-modeling/SKILL.md"
  jq -n --arg plugin "$plugin" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$plugin,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$registry"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pgrep-nm some-proj --mode no-mistakes >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pgrep-direct some-proj --mode direct-PR >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pgrep-local some-proj --mode local-only >/dev/null 2>&1
  FM_HOME="$home" FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
    "$ROOT/bin/fm-brief.sh" pgrep-design some-proj --design --mode no-mistakes >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pgrep-scout some-proj --scout >/dev/null 2>&1
  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops' \
    "$ROOT/bin/fm-brief.sh" pgrep-secondmate --secondmate --no-projects >/dev/null 2>&1

  local id
  for id in pgrep-nm pgrep-direct pgrep-local pgrep-design; do
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep 'Never poll with `pgrep -f` or `pkill -f` on a pattern that appears in your own command line' "$brief" \
      "$id: brief lost the self-matching pgrep/pkill prohibition"
    assert_grep 'the wait matches itself and cannot exit' "$brief" \
      "$id: brief lost the self-match never-exits consequence"
    assert_grep 'Wait on the actual PID, or run the command in the foreground' "$brief" \
      "$id: brief lost the wait-on-PID-or-foreground remedy"
    assert_grep 'when killing, kill by PID' "$brief" \
      "$id: brief lost the kill-by-PID remedy"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    count=$(grep -c -F 'Never poll with `pgrep -f` or `pkill -f`' "$brief" || true)
    [ "$count" -eq 1 ] || fail "$id: self-matching pgrep warning appeared $count times, want exactly once"
  done

  for id in pgrep-scout pgrep-secondmate; do
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_no_grep 'Never poll with `pgrep -f` or `pkill -f`' "$brief" \
      "$id: brief that does not teach backgrounding carried the pgrep warning"
    assert_no_grep 'when killing, kill by PID' "$brief" \
      "$id: brief that does not teach backgrounding carried the kill-by-PID remedy"
  done

  pass "fm-brief.sh: ship and design briefs warn once against self-matching pgrep waits"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_tracked_and_report_tasks() {
  local home plugin registry id brief
  home="$TMP_ROOT/herdr-gate-home"
  plugin="$TMP_ROOT/herdr-gate-plugin"
  registry="$TMP_ROOT/herdr-gate-registry.json"
  mkdir -p "$home/data" "$plugin/skills/productivity/grilling" \
    "$plugin/skills/engineering/domain-modeling"
  printf 'grilling\n' > "$plugin/skills/productivity/grilling/SKILL.md"
  printf 'domain modeling\n' > "$plugin/skills/engineering/domain-modeling/SKILL.md"
  jq -n --arg plugin "$plugin" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$plugin,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$registry"
  for kind in ship design scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    elif [ "$kind" = design ]; then
      FM_HOME="$home" FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
        "$ROOT/bin/fm-brief.sh" "$id" firstmate --design --mode no-mistakes >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship, design, and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never an ordinary task brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    case "$kind" in
      ship)
        # Ship brief teaches the pause verb through the discriminator and worked examples.
        # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
        assert_grep '`awaiting: rate limit resets at 06:00 UTC`' "$brief" \
          "$kind brief did not instruct the configured pause status in its worked example"
        # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
        assert_grep '`awaiting:` is for a bounded external wait expected to clear on its own' "$brief" \
          "$kind brief did not define the configured pause verb in the discriminator"
        ;;
      *)
        # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
        assert_grep 'Use `awaiting: {why}`' "$brief" \
          "$kind brief did not instruct the configured pause status"
        ;;
    esac
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# The retrieval instruction is on demand: a brief points at the brain only when
# the home has an index to read, so a home with no brain keeps briefs unchanged
# and one with a brain teaches every scaffold the same citation and hosted-think
# rule. bin/fm-recall.sh owns the retrieval contract this line points at.
test_brain_instruction_tracks_whether_the_home_has_one() {
  local nobrain="$TMP_ROOT/brain-absent" withbrain="$TMP_ROOT/brain-present" brief kind
  mkdir -p "$nobrain/data" "$withbrain/data/gbrain/pglite"

  FM_HOME="$nobrain" "$ROOT/bin/fm-brief.sh" nb-ship repo --mode no-mistakes >/dev/null 2>&1 \
    || fail "scaffold failed for a home with no brain"
  assert_no_grep "fm-recall.sh" "$nobrain/data/nb-ship/brief.md" \
    "a home with no brain must not point a crewmate at retrieval"

  FM_HOME="$withbrain" "$ROOT/bin/fm-brief.sh" wb-ship repo --mode no-mistakes >/dev/null 2>&1 \
    || fail "ship scaffold failed for a home with a brain"
  FM_HOME="$withbrain" "$ROOT/bin/fm-brief.sh" wb-scout repo --scout >/dev/null 2>&1 \
    || fail "scout scaffold failed for a home with a brain"
  FM_SECONDMATE_CHARTER='Supervise alpha.' FM_HOME="$withbrain" \
    "$ROOT/bin/fm-brief.sh" wb-sm --secondmate alpha >/dev/null 2>&1 \
    || fail "secondmate scaffold failed for a home with a brain"

  for kind in wb-ship wb-scout wb-sm; do
    brief="$withbrain/data/$kind/brief.md"
    assert_grep "$ROOT/bin/fm-recall.sh search" "$brief" \
      "$kind must name the retrieval command by absolute path"
    assert_grep '<source>:<slug>' "$brief" "$kind must say how to cite a result"
    assert_grep 'hosted provider' "$brief" \
      "$kind must say that hosted synthesis leaves this host"
    assert_no_grep 'gbrain call' "$brief" \
      "$kind must not teach a crewmate to call GBrain directly"
  done
  pass "fm-brief.sh: the brain instruction appears only for a home that has one, in every scaffold"
}

# Both non-firstmate projects here are real clones under projects/, the layout
# docs/configuration.md describes: firstmate is the only project whose checkout
# is the home itself, so every other name resolves to its own object database
# and the git-common-dir comparison is what rejects it.
test_firstmate_repo_crew_persona_section() {
  local home same_repo_brief scout_brief other_repo_brief decoy_brief
  home="$TMP_ROOT/firstmate-repo-persona-home"
  mkdir -p "$home/projects" "$home/data"

  ln -sfn "$ROOT" "$home/projects/firstmate"
  local other
  for other in decoy-firstmate some-proj; do
    mkdir -p "$home/projects/$other"
    git -C "$home/projects/$other" init -q
    printf '# %s\n' "$other" > "$home/projects/$other/README.md"
    git -C "$home/projects/$other" add README.md
    git -C "$home/projects/$other" -c user.email=test@example.com -c user.name=test commit -qm init
  done

  # Ship: both facts. Breaks if the guidelines directive stops being
  # tracked-output-only in the wrong direction and is dropped from ship briefs too.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" fm-repo-ship firstmate --mode no-mistakes >/dev/null 2>&1
  same_repo_brief="$home/data/fm-repo-ship/brief.md"
  assert_grep 'You report to FIRSTMATE, not the captain.' "$same_repo_brief" \
    "firstmate-repo ship brief did not warn against adopting firstmate's captain address"
  # shellcheck disable=SC2016 # Literal backticks are part of the generated Markdown.
  assert_grep 'Load the `firstmate-coding-guidelines` skill first.' "$same_repo_brief" \
    "firstmate-repo ship brief did not require the coding-guidelines skill"
  assert_grep "This task changes firstmate's shared tracked material" "$same_repo_brief" \
    "firstmate-repo ship brief did not say why the coding-guidelines skill applies"

  # Scout: role fact only. Breaks if the section stops being split by KIND, which
  # would put "this task changes firstmate's shared tracked material" - a false
  # statement - into a brief whose only deliverable is a report.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" fm-repo-scout firstmate --scout >/dev/null 2>&1
  scout_brief="$home/data/fm-repo-scout/brief.md"
  assert_grep 'You report to FIRSTMATE, not the captain.' "$scout_brief" \
    "firstmate-repo scout brief did not warn against adopting firstmate's captain address"
  assert_no_grep 'firstmate-coding-guidelines' "$scout_brief" \
    "firstmate-repo scout brief must not carry the tracked-output coding-guidelines directive"
  assert_no_grep "changes firstmate's shared tracked material" "$scout_brief" \
    "firstmate-repo scout brief must not claim it changes shared tracked material"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" fm-decoy decoy-firstmate --mode no-mistakes >/dev/null 2>&1
  decoy_brief="$home/data/fm-decoy/brief.md"
  assert_no_grep 'You report to FIRSTMATE, not the captain.' "$decoy_brief" \
    "misnamed non-firstmate project must not receive firstmate-repo persona guidance"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" fm-other some-proj --mode no-mistakes >/dev/null 2>&1
  other_repo_brief="$home/data/fm-other/brief.md"
  assert_no_grep 'You report to FIRSTMATE, not the captain.' "$other_repo_brief" \
    "ordinary non-firstmate brief must not receive firstmate-repo persona guidance"

  # A name that resolves to no clone, in a home with no registry at all. Breaks
  # if resolution ever answers with a directory it did not resolve the name to,
  # since guidance must follow the git-common-dir verdict, not a lookup failure.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" fm-uncloned not-cloned-here --mode no-mistakes >/dev/null 2>&1
  assert_no_grep 'You report to FIRSTMATE, not the captain.' "$home/data/fm-uncloned/brief.md" \
    "a repo name with no clone in a non-firstmate home must not receive persona guidance"
  pass "fm-brief.sh: firstmate-repo persona guidance is git-common-dir gated and split by kind"
}

# This home IS the firstmate clone, the documented default, so firstmate has no
# clone under projects/ and a bare `firstmate` repo name resolves nowhere else.
# Positive case breaks if fm_brief_resolve_project_dir stops offering the home
# root to a name whose registry line declares that layout: the name resolves to
# nothing, the git-common-dir comparison never runs, and the guidance is
# silently absent from exactly the canonical call. Negative cases break if that
# candidate is ever offered on anything weaker - registration alone, or nothing
# at all - because every such name would resolve to the home, which in this
# layout IS firstmate's repo, and ordinary projects would then be told they are
# working in a checkout of firstmate.
test_firstmate_repo_crew_persona_without_a_projects_clone() {
  local data brief unregistered_brief uncloned_brief
  data="$TMP_ROOT/firstmate-home-data"
  mkdir -p "$data"
  [ ! -d "$ROOT/projects/firstmate" ] \
    || fail "fixture assumes the firstmate checkout has no projects/firstmate clone"
  [ ! -e "$ROOT/.fm-secondmate-home" ] \
    || fail "fixture assumes this checkout is a primary home, not a marked secondmate home"
  printf '%s\n' \
    '# Projects' \
    '' \
    '- firstmate [no-mistakes +yolo] - firstmate itself: this home IS the clone, so it lives at the home root rather than under projects/ (added 2026-08-04)' \
    '- some-clone [no-mistakes] - an ordinary registered project whose clone is not in this home yet (added 2026-08-04)' \
    > "$data/projects.md"

  # Run from a scratch directory so the relative-name branch cannot resolve.
  (cd "$TMP_ROOT" && FM_HOME="$ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$data" \
    FM_STATE_OVERRIDE="$TMP_ROOT/firstmate-home-state" \
    "$ROOT/bin/fm-brief.sh" fm-home-repo firstmate --mode no-mistakes >/dev/null 2>&1)
  brief="$data/fm-home-repo/brief.md"
  assert_grep 'You report to FIRSTMATE, not the captain.' "$brief" \
    "a home that is the firstmate clone itself produced no firstmate-repo persona guidance"
  # shellcheck disable=SC2016 # Literal backticks are part of the generated Markdown.
  assert_grep 'Load the `firstmate-coding-guidelines` skill first.' "$brief" \
    "a home that is the firstmate clone itself produced no coding-guidelines directive"

  # An intake spelling the registry does not carry, in the same firstmate home:
  # the clone directory is `ark-robhinhood` while `ark-robinhood` is the name
  # that circulates for gh-axi calls, so both reach this scaffold in practice.
  (cd "$TMP_ROOT" && FM_HOME="$ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$data" \
    FM_STATE_OVERRIDE="$TMP_ROOT/firstmate-home-state" \
    "$ROOT/bin/fm-brief.sh" fm-home-other ark-robinhood --mode no-mistakes >/dev/null 2>&1)
  unregistered_brief="$data/fm-home-other/brief.md"
  assert_grep 'disposable git worktree of ark-robinhood' "$unregistered_brief" \
    "the unregistered-name brief did not scaffold"
  assert_no_grep 'You report to FIRSTMATE, not the captain.' "$unregistered_brief" \
    "an unregistered project name must not resolve to the firstmate home and inherit its persona section"
  assert_no_grep "changes firstmate's shared tracked material" "$unregistered_brief" \
    "an unregistered project name must not be told it changes firstmate's tracked material"

  # Registered, but its line claims no home-root clone and the clone is simply
  # not in this home yet - register-then-clone ordering, or a renamed clone
  # directory. Registration alone must not put it in firstmate's own checkout.
  (cd "$TMP_ROOT" && FM_HOME="$ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$data" \
    FM_STATE_OVERRIDE="$TMP_ROOT/firstmate-home-state" \
    "$ROOT/bin/fm-brief.sh" fm-home-uncloned some-clone --mode no-mistakes >/dev/null 2>&1)
  uncloned_brief="$data/fm-home-uncloned/brief.md"
  assert_grep 'disposable git worktree of some-clone' "$uncloned_brief" \
    "the registered-but-uncloned brief did not scaffold"
  assert_no_grep 'You report to FIRSTMATE, not the captain.' "$uncloned_brief" \
    "a registered project with no home-root declaration must not inherit the firstmate persona section"
  assert_no_grep "changes firstmate's shared tracked material" "$uncloned_brief" \
    "a registered project with no home-root declaration must not be told it changes firstmate's tracked material"
  pass "fm-brief.sh: the home-root candidate needs a home-root registry declaration, not merely registration"
}

assert_design_dod_exact() {
  local mode=$1 brief=$2 expected actual
  case "$mode" in
    no-mistakes)
      IFS= read -r -d '' expected <<'EOF' || true
# Definition of done
Delivery contract: mode=no-mistakes
Before reporting the ADR ready, read and follow `__ROOT__/.agents/skills/decision-hold-lifecycle/SKILL.md` and pass its shared completion gate for every unresolved decision surfaced by the interview or ADR.
Inspect the branch diff and confirm the ADR is the only worker-authored tracked project change.
The final status summary must name the ADR path and concisely state the decisions taken.
This ADR ships through **no-mistakes**: `done:` means the PR is open with its checks green.
A clean local ADR commit is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR {url} checks green`.
The ADR is ready for validation only when committed on your branch.
When the ADR is complete and committed, append `paused: ADR complete and committed, ready to validate` and stop there; that handoff is a defined stopping point and a declared wait, and firstmate will then instruct you to run /no-mistakes to validate and ship the ADR PR.

You drive no-mistakes by responding to its gates, not by applying fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or apply findings yourself while a run is active - the pipeline applies every fix.
While you sit parked on a backgrounded `axi run` or `axi respond` call, rule 4's park-and-resume pairing applies: append `paused:` before you go idle and `working:` when the call returns.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its `AGENTS.md` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or apply the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
EOF
      ;;
    direct-PR)
      IFS= read -r -d '' expected <<'EOF' || true
# Definition of done
Delivery contract: mode=direct-PR
Before reporting the ADR ready, read and follow `__ROOT__/.agents/skills/decision-hold-lifecycle/SKILL.md` and pass its shared completion gate for every unresolved decision surfaced by the interview or ADR.
Inspect the branch diff and confirm the ADR is the only worker-authored tracked project change.
The final status summary must name the ADR path and concisely state the decisions taken.
This ADR ships **direct-PR**: you raise its PR yourself, without the no-mistakes pipeline.
The ADR is ready only when committed on your branch.
When the ADR is complete and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      IFS= read -r -d '' expected <<'EOF' || true
# Definition of done
Delivery contract: mode=local-only
Before reporting the ADR ready, read and follow `__ROOT__/.agents/skills/decision-hold-lifecycle/SKILL.md` and pass its shared completion gate for every unresolved decision surfaced by the interview or ADR.
Inspect the branch diff and confirm the ADR is the only worker-authored tracked project change.
The final status summary must name the ADR path and concisely state the decisions taken.
This ADR ships **local-only**: no remote, no PR, no pipeline.
The ADR is ready only when committed on your branch `fm/design-firstmate`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When the ADR is complete and committed, append `done: ready in branch fm/design-firstmate` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
EOF
      ;;
    *) fail "unknown design DOD mode: $mode" ;;
  esac
  expected=${expected%$'\n'}
  expected=${expected//__ROOT__/$ROOT}
  actual=$(sed -n '/^# Definition of done$/,$p' "$brief")
  [ "$actual" = "$expected" ] \
    || fail "design $mode definition of done changed"$'\n'"expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$actual"
  assert_not_contains "$actual" "implement" \
    "design $mode definition of done authorizes implementation"
  pass "design DOD $mode: exact rendered text authorizes no implementation"
}

test_design_brief_is_harness_independent_and_adr_only() {
  local home plugin registry brief out rc
  home="$TMP_ROOT/design-home"
  plugin="$TMP_ROOT/design-plugin"
  registry="$TMP_ROOT/design-registry.json"
  mkdir -p "$home/data" "$plugin/skills/productivity/grilling" \
    "$plugin/skills/engineering/domain-modeling"
  printf 'grilling\n' > "$plugin/skills/productivity/grilling/SKILL.md"
  printf 'domain modeling\n' > "$plugin/skills/engineering/domain-modeling/SKILL.md"
  jq -n --arg plugin "$plugin" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$plugin,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$registry"

  out=$(FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
    "$ROOT/bin/fm-brief.sh" design-task sample --design --mode no-mistakes 2>&1)
  rc=$?
  expect_code 0 "$rc" "complete design dependencies should scaffold"
  assert_contains "$out" "(design, mode=no-mistakes" \
    "design scaffold did not identify its task shape"
  brief="$home/data/design-task/brief.md"
  assert_grep 'This is an interactive DESIGN task' "$brief" \
    "design brief did not declare the profile"
  assert_grep 'identical on Claude, Codex, and Pi' "$brief" \
    "design brief did not carry the harness-independent resolution contract"
  assert_grep 'fm-design-skills.sh resolve' "$brief" \
    "design brief did not resolve the installed plugin dependency"
  assert_grep 'Never install, update, copy, vendor, pin, or modify that plugin' "$brief" \
    "design brief allowed worker-owned plugin lifecycle"
  assert_grep 'Use those skills for modeling and interrogation only' "$brief" \
    "design brief did not constrain the dependency capabilities"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Do not create or update `CONTEXT.md`' "$brief" \
    "design brief allowed the dependency to create a second tracked deliverable"
  assert_grep 'Record every resolved term only in the ADR' "$brief" \
    "design brief did not preserve the ADR as the resolved-term owner"
  assert_no_grep '# Project memory' "$brief" \
    "design brief exposed the ship-only project-memory deliverable path"
  assert_no_grep 'fm-ensure-agents-md.sh' "$brief" \
    "design brief allowed AGENTS.md creation as a second tracked deliverable"
  assert_grep 'Do not create or modify any other tracked project file' "$brief" \
    "design brief did not forbid every non-ADR tracked project change"
  assert_grep 'confirm the ADR is the only worker-authored tracked project change' "$brief" \
    "design brief did not require a final ADR-only diff check"
  assert_grep 'Ask exactly one decision question at a time' "$brief" \
    "design brief did not preserve the sequential interview"
  assert_grep 'docs/adr/NNNN-<slug>.md' "$brief" \
    "design brief did not define the fallback ADR location"
  assert_grep 'Do not implement the resulting design' "$brief" \
    "design brief allowed implementation to leak into the ADR task"
  assert_grep 'Delivery contract: mode=no-mistakes' "$brief" \
    "design brief did not carry the tracked-output delivery contract"

  out=$(FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
    "$ROOT/bin/fm-brief.sh" design-linked sample --design --mode direct-PR \
    --work-item github:https://github.com/acme/widget/issues/42 \
    --pr-target github:github.com/acme/widget 2>&1)
  rc=$?
  expect_code 0 "$rc" "a PR-based design brief should accept a resolved work item"
  assert_grep '<!-- firstmate-work-item=github:https://github.com/acme/widget/issues/42 -->' \
    "$home/data/design-linked/brief.md" \
    "design brief did not carry its work item through the tracked-output contract"

  mkdir -p "$home/projects"
  ln -sfn "$ROOT" "$home/projects/firstmate"
  out=$(FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
    "$ROOT/bin/fm-brief.sh" design-firstmate firstmate --design --mode local-only 2>&1)
  rc=$?
  expect_code 0 "$rc" "a firstmate-repo design brief should scaffold"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Load the `firstmate-coding-guidelines` skill first.' \
    "$home/data/design-firstmate/brief.md" \
    "firstmate-repo design brief did not retain its tracked-output coding guidance"
  assert_no_grep 'fm-ensure-agents-md.sh' "$home/data/design-firstmate/brief.md" \
    "firstmate-repo design brief reopened the project-memory deliverable path"

  assert_design_dod_exact no-mistakes "$home/data/design-task/brief.md"
  assert_design_dod_exact direct-PR "$home/data/design-linked/brief.md"
  assert_design_dod_exact local-only "$home/data/design-firstmate/brief.md"

  out=$(FM_HOME="$home" FM_MATTPOCOCK_PLUGIN_REGISTRY="$TMP_ROOT/missing-registry.json" \
    "$ROOT/bin/fm-brief.sh" missing-design sample --design --mode no-mistakes 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing plugin should refuse design scaffolding"
  assert_contains "$out" "do not install or copy them from a worker" \
    "design refusal did not preserve plugin ownership"
  assert_absent "$home/data/missing-design/brief.md" \
    "design scaffold wrote a brief despite a missing dependency"
  pass "fm-brief.sh: design profile is ADR-only and resolves identically across supported harnesses"
}

# A secondmate home is leased as a firstmate worktree, and bin/fm-home-seed.sh
# registers only the projects it seeds - never firstmate, which is no clone under
# projects/ - so this home structurally cannot carry the registry declaration
# while every crew task it runs against firstmate is a firstmate-repo task.
# Breaks if the marker stops opening the home-root candidate: the whole
# population whose purpose is firstmate-repo work silently loses the guidance.
# The paired negative breaks if the marker is ever treated as optional, which
# would hand the candidate to any unresolved name in a primary home again.
test_firstmate_repo_crew_persona_in_a_secondmate_home() {
  local upstream home brief unmarked_brief
  upstream="$TMP_ROOT/sm-upstream"
  home="$TMP_ROOT/sm-home"
  mkdir -p "$upstream"
  git -C "$upstream" init -q
  printf '# upstream\n' > "$upstream/README.md"
  git -C "$upstream" add README.md
  git -C "$upstream" -c user.email=test@example.com -c user.name=test commit -qm init
  git -C "$upstream" worktree add -q --detach "$home" >/dev/null 2>&1 \
    || fail "could not lease a worktree of the fixture firstmate repo"
  printf 'sm-persona\n' > "$home/.fm-secondmate-home"
  mkdir -p "$home/data"

  (cd "$TMP_ROOT" && FM_HOME="$home" FM_ROOT_OVERRIDE="$upstream" \
    FM_STATE_OVERRIDE="$TMP_ROOT/sm-home-state" \
    "$ROOT/bin/fm-brief.sh" sm-repo-ship firstmate --mode no-mistakes >/dev/null 2>&1)
  brief="$home/data/sm-repo-ship/brief.md"
  assert_grep 'You report to FIRSTMATE, not the captain.' "$brief" \
    "a secondmate home leased from the firstmate repo produced no firstmate-repo persona guidance"
  # shellcheck disable=SC2016 # Literal backticks are part of the generated Markdown.
  assert_grep 'Load the `firstmate-coding-guidelines` skill first.' "$brief" \
    "a secondmate home leased from the firstmate repo produced no coding-guidelines directive"

  rm -f "$home/.fm-secondmate-home"
  (cd "$TMP_ROOT" && FM_HOME="$home" FM_ROOT_OVERRIDE="$upstream" \
    FM_STATE_OVERRIDE="$TMP_ROOT/sm-home-state" \
    "$ROOT/bin/fm-brief.sh" sm-unmarked firstmate --mode no-mistakes >/dev/null 2>&1)
  unmarked_brief="$home/data/sm-unmarked/brief.md"
  assert_grep 'disposable git worktree of firstmate' "$unmarked_brief" \
    "the unmarked-home brief did not scaffold"
  assert_no_grep 'You report to FIRSTMATE, not the captain.' "$unmarked_brief" \
    "an unmarked home with no registry declaration must not resolve a name to its own root"
  pass "fm-brief.sh: a secondmate home's marker opens the home-root candidate its registry cannot declare"
}

test_resolved_line_and_pr_attribution_guidance() {
  local home plugin registry brief scout_brief design_brief sm_brief fm_brief
  home="$TMP_ROOT/attribution-home"
  plugin="$TMP_ROOT/attribution-plugin"
  registry="$TMP_ROOT/attribution-registry.json"
  mkdir -p "$home/data" "$home/projects" "$plugin/skills/productivity/grilling" \
    "$plugin/skills/engineering/domain-modeling"
  printf 'grilling\n' > "$plugin/skills/productivity/grilling/SKILL.md"
  printf 'domain modeling\n' > "$plugin/skills/engineering/domain-modeling/SKILL.md"
  jq -n --arg plugin "$plugin" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$plugin,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$registry"

  # 1. Ship brief (non-firstmate project)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-attribution sample --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/ship-attribution/brief.md"
  assert_grep 'You are instructed by firstmate; the captain is not in the loop.' "$brief" \
    "ship brief did not instruct worker on firstmate reporting line"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Name firstmate in `resolved:` lines, PR bodies, and commits unless the decision text explicitly states the captain was consulted.' "$brief" \
    "ship brief did not require firstmate attribution in status lines, PR bodies, and commits"

  # 2. Scout brief (non-firstmate project)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scout-attribution sample --scout >/dev/null 2>&1
  scout_brief="$home/data/scout-attribution/brief.md"
  assert_grep 'You are instructed by firstmate; the captain is not in the loop.' "$scout_brief" \
    "scout brief did not instruct worker on firstmate reporting line"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Name firstmate in `resolved:` lines, reports, and commits unless the decision text explicitly states the captain was consulted.' "$scout_brief" \
    "scout brief did not require firstmate attribution in status lines, reports, and commits"

  # 3. Design brief (non-firstmate project)
  FM_HOME="$home" FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
    "$ROOT/bin/fm-brief.sh" design-attribution sample --design --mode no-mistakes >/dev/null 2>&1
  design_brief="$home/data/design-attribution/brief.md"
  assert_grep 'you are instructed by firstmate and the captain is not in the loop' "$design_brief" \
    "design brief did not instruct worker on firstmate reporting line"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Name firstmate in `resolved:` lines, PR bodies, and commits unless the decision text explicitly states the captain was consulted.' "$design_brief" \
    "design brief did not require firstmate attribution in status lines, PR bodies, and commits"

  # 4. Secondmate charter
  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops' \
    "$ROOT/bin/fm-brief.sh" sm-attribution --secondmate --no-projects >/dev/null 2>&1
  sm_brief="$home/data/sm-attribution/brief.md"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Name the main firstmate in `resolved:` lines unless the decision text explicitly states the captain was consulted.' "$sm_brief" \
    "secondmate charter did not require main firstmate attribution in resolved status lines"

  # 5. Firstmate-repo section points to rules section without duplication under one-owner rule
  ln -sfn "$ROOT" "$home/projects/firstmate"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" fm-repo-attr firstmate --mode no-mistakes >/dev/null 2>&1
  fm_brief="$home/data/fm-repo-attr/brief.md"
  assert_grep 'follow the reporting line and attribution rules in the rules below.' "$fm_brief" \
    "firstmate-repo persona section did not point to the rules section"
  assert_no_grep 'and never attribute firstmate' "$fm_brief" \
    "firstmate-repo persona section duplicated the attribution contract instead of pointing to the single owner"

  pass "fm-brief.sh: resolved: lines and PR/commit attribution guidance is present in all brief variants"
}

# Ordinary Setup stays byte-stable via the no-issue goldens. These cases pin the
# continue-an-existing-branch strategy as a generated contract rather than a
# Task-section contradiction: the first action, the task-branch marker, and the
# isolation assertion must agree, and the flag must refuse the shapes that would
# silently recreate the original bug.
test_continue_branch_renders_setup_and_marker() {
  local home project plugin registry id continued brief iso br kind mode noun quoted
  home="$TMP_ROOT/continue-branch-home"
  project="$home/projects/some-proj"
  plugin="$TMP_ROOT/continue-branch-design-plugin"
  registry="$TMP_ROOT/continue-branch-design-registry.json"
  mkdir -p "$home/data" "$project" "$plugin/skills/productivity/grilling" \
    "$plugin/skills/engineering/domain-modeling"
  git init -q "$project"
  git -C "$project" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$project/base.txt"
  git -C "$project" add base.txt
  git -C "$project" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm base
  printf 'grilling\n' > "$plugin/skills/productivity/grilling/SKILL.md"
  printf 'domain modeling\n' > "$plugin/skills/engineering/domain-modeling/SKILL.md"
  jq -n --arg plugin "$plugin" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$plugin,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$registry"
  continued='fm/existing-pr-head'
  quoted="'$continued'"
  for kind in ship design; do
    for mode in no-mistakes direct-PR local-only; do
      id="continue-$kind-${mode//-}"
      if [ "$kind" = design ]; then
        FM_HOME="$home" FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
          "$ROOT/bin/fm-brief.sh" "$id" "$project" --design --mode "$mode" \
          --continue-branch "$continued" >/dev/null 2>&1 \
          || fail "$kind $mode --continue-branch should scaffold"
        noun=ADR
      else
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$project" --mode "$mode" \
          --continue-branch "$continued" >/dev/null 2>&1 \
          || fail "$kind $mode --continue-branch should scaffold"
        noun=task
      fi
      brief="$home/data/$id/brief.md"
      grep -qx "<!-- firstmate-task-branch=$continued -->" "$brief" \
        || fail "$kind $mode recorded the wrong continued branch"
      assert_no_grep "<!-- firstmate-task-branch=fm/$id -->" "$brief" \
        "$kind $mode recorded the unused fm/<task-id> marker"
      assert_grep "1. First action: continue existing branch \`$continued\` from detached HEAD." "$brief" \
        "$kind $mode did not replace the Setup first action"
      assert_no_grep "git checkout -b fm/$id" "$brief" \
        "$kind $mode still instructed git checkout -b fm/<task-id>"
      assert_no_grep 'committed on your branch' "$brief" \
        "$kind $mode definition of done contradicts detached continuation"
      assert_grep "Do not create \`fm/$id\`." "$brief" \
        "$kind $mode did not forbid creating fm/<task-id>"
      iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
      br=$(grep -n 'First action: continue existing branch' "$brief" | head -1 | cut -d: -f1)
      [ -n "$iso" ] && [ -n "$br" ] && [ "$iso" -lt "$br" ] \
        || fail "$kind $mode must keep isolation before branch continuation"
      case "$mode" in
        no-mistakes)
          assert_grep "git fetch origin $quoted" "$brief" \
            "$kind $mode omitted the shell-quoted branch fetch"
          assert_grep "git push origin 'HEAD:$continued'" "$brief" \
            "$kind $mode omitted the shell-quoted in-place PR update"
          assert_grep "This $noun continues an existing PR through **no-mistakes**" "$brief" \
            "$kind $mode did not identify the existing PR handoff"
          assert_grep 'done: PR https://... checks green' "$brief" \
            "$kind $mode did not require the existing PR full HTTPS URL"
          # shellcheck disable=SC2016 # Literal backticks are part of the generated Markdown.
          assert_no_grep 'open a PR with `gh-axi`' "$brief" \
            "$kind $mode still tells the worker to open a duplicate PR"
          ;;
        direct-PR)
          assert_grep "git fetch origin $quoted" "$brief" \
            "$kind $mode omitted the shell-quoted branch fetch"
          assert_grep "git push origin 'HEAD:$continued'" "$brief" \
            "$kind $mode omitted the shell-quoted in-place PR update"
          assert_grep "This $noun continues an existing PR through **direct-PR**" "$brief" \
            "$kind $mode did not identify the existing PR handoff"
          assert_grep 'confirm the existing PR was updated' "$brief" \
            "$kind $mode did not require confirmation of the in-place update"
          assert_grep 'done: PR https://...' "$brief" \
            "$kind $mode did not require the existing PR full HTTPS URL"
          # shellcheck disable=SC2016 # Literal backticks are part of the generated Markdown.
          assert_no_grep 'open a PR with `gh-axi`' "$brief" \
            "$kind $mode still tells the worker to open a duplicate PR"
          ;;
        local-only)
          assert_grep "git checkout --detach $quoted" "$brief" \
            "$kind $mode did not detach at the shell-quoted existing branch"
          assert_grep "git update-ref 'refs/heads/$continued' HEAD" "$brief" \
            "$kind $mode omitted the shell-quoted local ref update"
          assert_grep "committed at detached HEAD and local branch \`$continued\` points to that commit" "$brief" \
            "$kind $mode definition of done does not match detached continuation"
          assert_no_grep 'git push origin' "$brief" \
            "$kind $mode instructed a remote push"
          assert_grep "Advance branch \`$continued\` without checking it out" "$brief" \
            "$kind $mode still told the worker to work on the held branch"
          ;;
      esac
    done
  done

  id='continue-shell-safe'
  # shellcheck disable=SC2016 # Literal command substitution is an intentional fixture.
  continued='feature/$(touch-owned)'
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$project" --mode direct-PR \
    --continue-branch "$continued" >/dev/null 2>&1 \
    || fail "shell-metacharacter branch should render safely"
  brief="$home/data/$id/brief.md"
  assert_grep "git fetch origin '$continued'" "$brief" \
    "continue-branch fetch operand is not shell quoted"
  assert_grep "git push origin 'HEAD:$continued'" "$brief" \
    "continue-branch push operand is not shell quoted"

  pass "fm-brief.sh: all continuation mode and kind combinations agree"
}

test_continue_branch_flag_validation() {
  local home project caller rc
  home="$TMP_ROOT/continue-branch-validation-home"
  project="$home/projects/some-proj"
  mkdir -p "$home/data" "$project"
  git init -q "$project"
  git -C "$project" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$project/base.txt"
  git -C "$project" add base.txt
  git -C "$project" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm base

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-missing some-proj --mode no-mistakes --continue-branch \
    > "$home/missing.stdout" 2> "$home/missing.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch without a value should fail"
  assert_grep 'requires a value' "$home/missing.stderr" \
    "--continue-branch without a value did not explain the missing argument"
  assert_absent "$home/data/continue-missing/brief.md" \
    "--continue-branch without a value wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-empty "$project" --mode no-mistakes --continue-branch= \
    > "$home/empty.stdout" 2> "$home/empty.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch= should fail"
  assert_grep 'requires a git branch name' "$home/empty.stderr" \
    "--continue-branch= did not refuse an empty name"
  assert_absent "$home/data/continue-empty/brief.md" \
    "--continue-branch= wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-bad "$project" --mode no-mistakes --continue-branch 'bad..name' \
    > "$home/bad.stdout" 2> "$home/bad.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch with an invalid ref should fail"
  assert_grep 'valid git branch name' "$home/bad.stderr" \
    "--continue-branch bad..name did not explain the invalid ref"
  assert_absent "$home/data/continue-bad/brief.md" \
    "--continue-branch bad..name wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-default "$project" --mode no-mistakes \
    --continue-branch fm/continue-default \
    > "$home/default.stdout" 2> "$home/default.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch fm/<task-id> should fail"
  assert_grep 'ordinary new-branch strategy' "$home/default.stderr" \
    "--continue-branch fm/<task-id> did not tell the caller to omit the flag"
  assert_absent "$home/data/continue-default/brief.md" \
    "--continue-branch fm/<task-id> wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-main "$project" --mode no-mistakes \
    --continue-branch main > "$home/main.stdout" 2> "$home/main.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch main should fail"
  assert_grep "cannot name the repository default branch 'main'" "$home/main.stderr" \
    "--continue-branch main did not protect the resolved default branch"
  assert_absent "$home/data/continue-main/brief.md" \
    "--continue-branch main wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-qualified "$project" --mode no-mistakes \
    --continue-branch refs/heads/main > "$home/qualified.stdout" 2> "$home/qualified.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch refs/heads/main should fail"
  assert_grep 'outside the refs/ namespace' "$home/qualified.stderr" \
    "--continue-branch accepted a fully qualified default-branch destination"
  assert_absent "$home/data/continue-qualified/brief.md" \
    "--continue-branch refs/heads/main wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-reserved "$project" --mode no-mistakes \
    --continue-branch FETCH_HEAD > "$home/reserved.stdout" 2> "$home/reserved.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch FETCH_HEAD should fail"
  assert_grep "reserved ref name 'FETCH_HEAD'" "$home/reserved.stderr" \
    "--continue-branch accepted a revision-sensitive reserved ref name"
  assert_absent "$home/data/continue-reserved/brief.md" \
    "--continue-branch FETCH_HEAD wrote a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-force "$project" --mode no-mistakes \
    --continue-branch +feature/existing > "$home/force.stdout" 2> "$home/force.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch +feature/existing should fail"
  assert_grep 'refspec force prefix' "$home/force.stderr" \
    "--continue-branch accepted a refspec force prefix"
  assert_absent "$home/data/continue-force/brief.md" \
    "--continue-branch +feature/existing wrote a brief"

  caller="$home/caller"
  git init -q "$caller"
  git -C "$caller" symbolic-ref HEAD refs/heads/main
  printf 'caller\n' > "$caller/caller.txt"
  git -C "$caller" add caller.txt
  git -C "$caller" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm caller
  git -C "$caller" checkout -qb previous
  git -C "$caller" checkout -q main
  (cd "$caller" && FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-dwim "$project" \
    --mode no-mistakes --continue-branch '@{-1}') \
    > "$home/dwim.stdout" 2> "$home/dwim.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch @{-1} should fail"
  assert_grep 'literal branch without revision shorthand' "$home/dwim.stderr" \
    "--continue-branch accepted checkout-history shorthand"
  assert_absent "$home/data/continue-dwim/brief.md" \
    "--continue-branch @{-1} wrote a brief"

  # shellcheck disable=SC2016 # Literal backticks are an intentional unsafe-name fixture.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" continue-markdown "$project" --mode no-mistakes \
    --continue-branch 'feature/`unsafe`' > "$home/markdown.stdout" 2> "$home/markdown.stderr"
  rc=$?
  expect_code 1 "$rc" "--continue-branch with a Markdown delimiter should fail"
  assert_grep 'cannot contain a backtick' "$home/markdown.stderr" \
    "--continue-branch did not protect rendered Markdown"
  assert_absent "$home/data/continue-markdown/brief.md" \
    "unsafe --continue-branch wrote a brief"

  pass "fm-brief.sh: --continue-branch rejects invalid and protected names"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_design_help_authorizes_no_implementation
test_issue_traceability_is_strictly_opt_in
test_issue_argument_validation_and_delivery_mode_guards
test_no_issue_briefs_match_exact_goldens
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_status_protocol_closes_reporting_gaps
test_status_protocol_teaches_blocked_for_firstmate_waits
test_status_protocol_warns_against_self_matching_pgrep
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_tracked_and_report_tasks
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_brain_instruction_tracks_whether_the_home_has_one
test_firstmate_repo_crew_persona_section
test_firstmate_repo_crew_persona_without_a_projects_clone
test_design_brief_is_harness_independent_and_adr_only
test_firstmate_repo_crew_persona_in_a_secondmate_home
test_resolved_line_and_pr_attribution_guidance
test_continue_branch_renders_setup_and_marker
test_continue_branch_flag_validation
printf '\nall fm-brief tests passed\n'
