#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Non-ASCII blank padding (task fm-afk-injection-wedge) -------------------
#
# A harness may pad an otherwise-empty composer row with a non-ASCII blank
# instead of an ASCII space - verified real claude 2.x pads its EMPTY composer
# with U+00A0 NO-BREAK SPACE. Bash's `[:space:]` trims treat no non-ASCII blank
# as whitespace under any locale the fleet runs, so the pad survived every trim
# as "real typed content", the row classified `pending`, and
# the away-mode injector - which injects only into an affirmatively `empty`
# composer - deferred every buffered escalation against an idle, injectable
# primary until the captain came back.

test_non_ascii_blank_pad_is_empty() {
  local b out
  # U+00A0 (the verified claude pad) plus the other blanks a TUI may pad with.
  for b in $'\xc2\xa0' $'\xe2\x80\x87' $'\xe2\x80\xaf' $'\xe3\x80\x80' $'\xe2\x80\x8b' $'\xef\xbb\xbf'; do
    out=$(classify 0 "❯${b}")
    [ "$out" = empty ] \
      || fail "an empty agent composer padded with a non-ASCII blank must read empty, got '$out'"
    # Bordered callers hand over already-border-stripped content (see the
    # <content> contract), so the box contributes only its blank pad.
    out=$(classify 1 "$b")
    [ "$out" = empty ] \
      || fail "a bordered composer holding only a non-ASCII blank must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a composer padded with a non-ASCII blank reads empty, not pending (the away-mode injection wedge)"
}

test_non_ascii_blank_pad_with_text_is_pending() {
  local out
  # The fold must not become a general "non-empty composer reads empty" escape:
  # any VISIBLE character still means unsubmitted work and must refuse injection.
  out=$(classify 0 $'\xe2\x9d\xaf\xc2\xa0merge PR 512?')
  [ "$out" = pending ] || fail "real text after a U+00A0 pad must stay pending, got '$out'"
  out=$(classify 1 $'\xc2\xa0deploy staging\xc2\xa0')
  [ "$out" = pending ] || fail "real text between U+00A0 pads must stay pending, got '$out'"
  pass "fm_composer_classify_content: visible text surrounded by non-ASCII blanks still reads pending"
}

test_non_ascii_blank_pad_does_not_revive_a_dead_shell() {
  local g out
  # The dead-shell safety verdict must survive the fold: a bare shell prompt
  # padded with U+00A0 is still an unsafe injection target, never empty.
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "${g}"$'\xc2\xa0')
    [ "$out" = unknown ] \
      || fail "a bare shell glyph '$g' padded with U+00A0 must stay unknown, got '$out'"
  done
  pass "fm_composer_classify_content: the non-ASCII blank fold does not weaken the dead-shell refusal"
}

# The subshell-local LC_ALL is the point of this test - each case must run under
# C/POSIX without leaking that locale into the rest of the suite.
# shellcheck disable=SC2030,SC2031
test_multibyte_agent_glyph_is_stripped_whole() {
  local out
  # The leading glyph is removed as a literal prefix, not by character count:
  # under the fleet's C/POSIX locale `${content#?}` drops one BYTE, which left
  # the two trailing bytes of ❯ / › behind to re-read as real content.
  # LC_ALL must be EXPORTED into the locale bash actually parses patterns under,
  # so a bare `LC_ALL=C classify ...` command prefix would not exercise this.
  out=$( export LC_ALL=C; classify 0 '❯' )
  [ "$out" = empty ] || fail "a bare '❯' must read empty under LC_ALL=C, got '$out'"
  out=$( export LC_ALL=C; classify 0 '❯ Type a message...' '^Type a message\.\.\.$' )
  [ "$out" = empty ] \
    || fail "an idle placeholder behind a multibyte glyph must read empty under LC_ALL=C, got '$out'"
  out=$( export LC_ALL=C; classify 0 '› Type a message...' '^Type a message\.\.\.$' )
  [ "$out" = empty ] \
    || fail "an idle placeholder behind '›' must read empty under LC_ALL=C, got '$out'"
  pass "fm_composer_classify_content: a multibyte agent glyph is stripped whole, locale-independently"
}

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

test_non_ascii_blank_pad_is_empty
test_non_ascii_blank_pad_with_text_is_pending
test_non_ascii_blank_pad_does_not_revive_a_dead_shell
test_multibyte_agent_glyph_is_stripped_whole
test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
printf '\nall fm-composer-lib tests passed\n'
