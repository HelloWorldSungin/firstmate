#!/usr/bin/env bash
# Unit tests for bin/fm-launch-lib.sh - the per-harness launch template and the
# --model / effort flag renderers. Covers the crew-only cursor/agy adapters and
# pins the existing harnesses so the extraction from fm-spawn.sh stays faithful
# (tests/fm-spawn-dispatch-profile.test.sh separately proves the same strings
# reach a real spawn).
# The expected launch strings below deliberately contain a literal, unexpanded
# $(cat __BRIEF__): they assert the template text fm-spawn substitutes later, so
# single quotes (no expansion) are correct here. File-wide directive (before the
# first command) so every literal-template assertion is covered.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-launch-lib.sh
. "$ROOT/bin/fm-launch-lib.sh"

assert_eq() {  # <actual> <expected> <msg>
  [ "$1" = "$2" ] || fail "$3"$'\n'"expected: $2"$'\n'"actual:   $1"
}

# --- fm_launch_template ------------------------------------------------------

test_cursor_template() {
  assert_eq "$(fm_launch_template cursor ship)" \
    'cursor-agent --trust --force __MODELFLAG__"$(cat __BRIEF__)"' \
    "cursor ship template must launch cursor-agent with --trust --force and no effort placeholder"
  # kind is irrelevant for cursor (crew-only, no secondmate variant).
  assert_eq "$(fm_launch_template cursor scout)" "$(fm_launch_template cursor ship)" \
    "cursor scout template must match ship template"
  pass "cursor template: --trust --force, model-only, no effort placeholder"
}

test_agy_template() {
  assert_eq "$(fm_launch_template agy ship)" \
    'agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--prompt-interactive "$(cat __BRIEF__)"' \
    "agy ship template must skip permissions, thread model+effort, and pass the brief to --prompt-interactive"
  assert_eq "$(fm_launch_template agy scout)" "$(fm_launch_template agy ship)" \
    "agy scout template must match ship template"
  pass "agy template: --dangerously-skip-permissions + --prompt-interactive brief"
}

test_existing_templates_unchanged() {
  assert_eq "$(fm_launch_template claude ship)" \
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' \
    "claude template drifted"
  assert_eq "$(fm_launch_template grok ship)" \
    'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' \
    "grok template drifted"
  # codex/pi have distinct secondmate variants; confirm the crew variant is stable.
  assert_contains "$(fm_launch_template codex ship)" 'touch __TURNEND__' \
    "codex crew template lost its notify turn-end"
  assert_contains "$(fm_launch_template pi ship)" '-e __PIEXT__' \
    "pi crew template lost its turn-end extension"
  pass "existing harness templates remain byte-stable after extraction"
}

test_unknown_harness_returns_nonzero() {
  if fm_launch_template bogus ship >/dev/null 2>&1; then
    fail "unknown harness must return non-zero so the caller can fall back to a raw launch command"
  fi
  pass "unknown harness returns non-zero"
}

# --- fm_launch_model_flag ----------------------------------------------------

test_cursor_model_passthrough() {
  # cursor encodes effort inside a parameterized model string; --model must carry
  # it through verbatim (quoted whole, brackets and = intact).
  assert_eq "$(fm_launch_model_flag cursor 'composer-2.5[effort=high]')" \
    "--model 'composer-2.5[effort=high]' " \
    "cursor --model must pass the parameterized model string through unmodified"
  pass "cursor --model passes a parameterized model string through verbatim"
}

test_agy_model_flag() {
  assert_eq "$(fm_launch_model_flag agy gemini-3-pro)" "--model 'gemini-3-pro' " \
    "agy --model flag missing"
  pass "agy renders --model"
}

test_model_flag_empty_and_default() {
  assert_eq "$(fm_launch_model_flag cursor '')" "" "empty model must render nothing"
  assert_eq "$(fm_launch_model_flag agy default)" "" "default model must render nothing"
  pass "model flag omits empty/default"
}

# --- fm_launch_effort_flag ---------------------------------------------------

test_cursor_has_no_effort_flag() {
  # cursor has NO standalone effort flag at any level; effort lives in the model
  # string, so the effort renderer must always be empty for cursor.
  local e
  for e in low medium high xhigh max; do
    assert_eq "$(fm_launch_effort_flag cursor "$e")" "" \
      "cursor must never render an effort flag (got one for '$e')"
  done
  pass "cursor never renders a standalone effort flag"
}

test_agy_effort_vocabulary() {
  assert_eq "$(fm_launch_effort_flag agy low)" "--effort 'low' " "agy low effort"
  assert_eq "$(fm_launch_effort_flag agy medium)" "--effort 'medium' " "agy medium effort"
  assert_eq "$(fm_launch_effort_flag agy high)" "--effort 'high' " "agy high effort"
  # agy --help advertises low|medium|high only; xhigh/max are omitted, not guessed.
  assert_eq "$(fm_launch_effort_flag agy xhigh)" "" "agy must omit unsupported xhigh"
  assert_eq "$(fm_launch_effort_flag agy max)" "" "agy must omit unsupported max"
  pass "agy renders --effort for low/medium/high and omits xhigh/max"
}

test_existing_effort_flags_unchanged() {
  assert_eq "$(fm_launch_effort_flag claude max)" "--effort 'max' " "claude effort drifted"
  assert_eq "$(fm_launch_effort_flag codex high)" "-c 'model_reasoning_effort=\"high\"' " "codex effort drifted"
  assert_eq "$(fm_launch_effort_flag grok high)" "--reasoning-effort 'high' " "grok effort drifted"
  assert_eq "$(fm_launch_effort_flag grok max)" "" "grok must still omit max"
  assert_eq "$(fm_launch_effort_flag pi max)" "--thinking 'max' " "pi effort drifted"
  assert_eq "$(fm_launch_effort_flag opencode high)" "" "opencode must still render no effort"
  pass "existing harness effort renderers remain stable after extraction"
}

test_cursor_template
test_agy_template
test_existing_templates_unchanged
test_unknown_harness_returns_nonzero
test_cursor_model_passthrough
test_agy_model_flag
test_model_flag_empty_and_default
test_cursor_has_no_effort_flag
test_agy_effort_vocabulary
test_existing_effort_flags_unchanged

echo "# all fm-launch-lib tests passed"
