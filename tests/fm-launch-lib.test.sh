#!/usr/bin/env bash
# Unit tests for bin/fm-launch-lib.sh - the per-harness launch template and the
# --model / effort flag renderers. Covers the crew-only cursor/agy adapters and
# pins the existing harnesses so the extraction from fm-spawn.sh stays faithful
# (tests/fm-spawn-dispatch-profile.test.sh separately proves the same strings
# reach a real spawn).
# The expected launch strings below deliberately contain a literal, unexpanded
# $(__OPINPUT__ encode launch-brief < __BRIEF__): they assert the template text fm-spawn substitutes later, so
# single quotes (no expansion) are correct here. File-wide directive (before the
# first command) so every literal-template assertion is covered.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-launch-lib.sh
. "$ROOT/bin/fm-launch-lib.sh"

TMP_LAUNCH_ROOT=$(fm_test_tmproot fm-launch-lib)

assert_eq() {  # <actual> <expected> <msg>
  [ "$1" = "$2" ] || fail "$3"$'\n'"expected: $2"$'\n'"actual:   $1"
}

# --- fm_launch_render --------------------------------------------------------

test_render_substitutes_operational_input_and_pi_env() {
  local rendered
  rendered=$(fm_launch_render \
    '__PIBRIEFENV__ cursor-agent __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' \
    "--model 'composer' " "" "'/tmp/brief.md'" "" "" "" "" \
    "'/opt/firstmate/bin/fm-operational-input.sh'" "FM_FIRSTMATE_PI_LAUNCH_BRIEF='/tmp/brief.md'")
  assert_eq "$rendered" \
    'FM_FIRSTMATE_PI_LAUNCH_BRIEF='\''/tmp/brief.md'\'' cursor-agent --model '\''composer'\'' "$('\''/opt/firstmate/bin/fm-operational-input.sh'\'' encode launch-brief < '\''/tmp/brief.md'\'')"' \
    "launch rendering must substitute the operational-input path and Pi brief environment"
  pass "launch rendering substitutes operational input and Pi brief environment"
}

test_render_rejects_unknown_placeholder() {
  local output
  if output=$(fm_launch_render \
    'cursor-agent __FUTURE_PLACEHOLDER__' "" "" "" "" "" "" "" "" "" 2>&1); then
    fail "launch rendering must reject an unknown placeholder"
  fi
  assert_contains "$output" "__FUTURE_PLACEHOLDER__" \
    "launch rendering must report the offending placeholder"
  pass "launch rendering fails loudly on an unknown placeholder"
}

# --- fm_launch_template ------------------------------------------------------

test_cursor_template() {
  assert_eq "$(fm_launch_template cursor ship)" \
    'cursor-agent --trust --force __MODELFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' \
    "cursor ship template must launch cursor-agent with --trust --force and no effort placeholder"
  # kind is irrelevant for cursor (crew-only, no secondmate variant).
  assert_eq "$(fm_launch_template cursor scout)" "$(fm_launch_template cursor ship)" \
    "cursor scout template must match ship template"
  pass "cursor template: --trust --force, model-only, no effort placeholder"
}

test_agy_template() {
  assert_eq "$(fm_launch_template agy ship)" \
    'agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--prompt-interactive "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' \
    "agy ship template must skip permissions, thread model+effort, and pass the brief to --prompt-interactive"
  assert_eq "$(fm_launch_template agy scout)" "$(fm_launch_template agy ship)" \
    "agy scout template must match ship template"
  pass "agy template: --dangerously-skip-permissions + --prompt-interactive brief"
}

test_existing_templates_unchanged() {
  assert_eq "$(fm_launch_template claude ship)" \
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' \
    "claude template drifted"
  assert_eq "$(fm_launch_template grok ship)" \
    'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' \
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

# --- fm_launch_raw_restricted_harness (B1 raw-command bypass guard) ----------

test_raw_restricted_harness_resolution() {
  # Direct executables.
  assert_eq "$(fm_launch_raw_restricted_harness 'cursor-agent --trust --force')" cursor "direct cursor-agent"
  assert_eq "$(fm_launch_raw_restricted_harness 'cursor --trust')" cursor "direct cursor"
  assert_eq "$(fm_launch_raw_restricted_harness 'agy --dangerously-skip-permissions')" agy "direct agy"
  # A full path is resolved by basename.
  assert_eq "$(fm_launch_raw_restricted_harness '/home/x/.local/bin/agy -p hi')" agy "agy via absolute path"
  # env wrapper (with and without options / NAME=val).
  assert_eq "$(fm_launch_raw_restricted_harness 'env agy --effort high')" agy "env agy"
  assert_eq "$(fm_launch_raw_restricted_harness 'env FOO=1 cursor-agent --force')" cursor "env NAME=val cursor-agent"
  assert_eq "$(fm_launch_raw_restricted_harness 'env -u HOME agy')" agy "env -u NAME agy"
  assert_eq "$(fm_launch_raw_restricted_harness 'env -i cursor-agent --force')" cursor "env -i cursor-agent"
  # Leading assignment prefixes.
  assert_eq "$(fm_launch_raw_restricted_harness 'FOO=1 agy -p hi')" agy "assignment-prefixed agy"
  assert_eq "$(fm_launch_raw_restricted_harness 'FOO=1 BAR=2 cursor-agent')" cursor "two assignments then cursor-agent"
  # Non-restricted commands resolve to nothing.
  assert_eq "$(fm_launch_raw_restricted_harness 'claude --dangerously-skip-permissions')" "" "claude is not restricted"
  assert_eq "$(fm_launch_raw_restricted_harness 'my-wrapper --run')" "" "an unrelated wrapper is not restricted"
  assert_eq "$(fm_launch_raw_restricted_harness 'env FOO=1 codex')" "" "env codex is not restricted"
  pass "fm_launch_raw_restricted_harness resolves cursor-agent/agy through env and assignment prefixes"
}

test_raw_restricted_harness_shell_wrappers() {
  # B1 re-review: a QUOTED shell-wrapper command hides the real executable inside a
  # quoted string, so the raw token is e.g. "'agy", not "agy". The fail-closed
  # backstop neutralizes quoting/separators before scanning.
  assert_eq "$(fm_launch_raw_restricted_harness "bash -lc 'agy --dangerously-skip-permissions'")" agy "bash -lc 'agy ...'"
  assert_eq "$(fm_launch_raw_restricted_harness "bash -lc 'cursor-agent --trust --force'")" cursor "bash -lc 'cursor-agent ...'"
  assert_eq "$(fm_launch_raw_restricted_harness 'sh -c "agy -p hi"')" agy 'sh -c "agy ..."'
  assert_eq "$(fm_launch_raw_restricted_harness 'bash -c "cursor-agent"')" cursor 'bash -c "cursor-agent"'
  assert_eq "$(fm_launch_raw_restricted_harness "env bash -lc 'agy'")" agy "env bash -lc 'agy'"
  assert_eq "$(fm_launch_raw_restricted_harness "zsh -ic 'x=1; agy'")" agy "zsh -ic with a separator"
  # Wrappers that do NOT invoke cursor/agy still resolve to nothing.
  assert_eq "$(fm_launch_raw_restricted_harness "bash -lc 'echo hello world'")" "" "harmless wrapped command"
  assert_eq "$(fm_launch_raw_restricted_harness "bash -lc 'claude --x'")" "" "wrapped claude is not restricted"
  pass "fm_launch_raw_restricted_harness sees through quoted shell-wrapper commands (bash -lc 'agy ...')"
}

test_raw_restricted_harness_variable_indirection() {
  # B1 second re-review: variable/command-substitution indirection can expand to a
  # restricted executable the literal scan cannot see. Since the raw command is run
  # by the pane shell, any unresolved shell expansion is refused as 'unresolved'.
  assert_eq "$(fm_launch_raw_restricted_harness "AGY=agy bash -lc '\$AGY --dangerously-skip-permissions'")" unresolved "assigned-var indirection to agy"
  assert_eq "$(fm_launch_raw_restricted_harness "CUR=cursor-agent bash -lc '\$CUR --trust'")" unresolved "assigned-var indirection to cursor-agent"
  assert_eq "$(fm_launch_raw_restricted_harness "bash -lc 'x=agy; eval \"\$x --x\"'")" unresolved "eval of a variable"
  assert_eq "$(fm_launch_raw_restricted_harness "bash -lc 'a=a; g=gy; \$a\$g --x'")" unresolved "split-token concatenation"
  assert_eq "$(fm_launch_raw_restricted_harness "custom-agent --home \$HOME")" unresolved "any \$ expansion is refused as unverifiable"
  assert_eq "$(fm_launch_raw_restricted_harness 'custom-agent --out `date`')" unresolved "backtick command substitution is refused"
  # No expansion and no restricted basename: allowed.
  assert_eq "$(fm_launch_raw_restricted_harness 'FOO=1 custom-agent --flag')" "" "expansion-free raw command stays allowed"
  pass "fm_launch_raw_restricted_harness refuses variable/command-substitution indirection as unresolved"
}

test_raw_guard_intercepts_every_bypass_spelling() {
  # B1 hardening: the robust, primary defense is the exec-time PATH shim
  # (fm_launch_write_raw_guard), not the string classifier. With the guard dir
  # ahead of a fake REAL cursor-agent/agy on PATH, EVERY shell spelling the pane
  # could use to resolve those binaries must hit the refusing shim, so the real
  # binary never runs. This is what closes quote-concat / brace / alias /
  # process-substitution AND the wrapper-script boundary uniformly - constructs a
  # launch-string scan can never model.
  local tmp shim realbin b execlog rc
  mkdir -p "$TMP_LAUNCH_ROOT"
  tmp=$(mktemp -d "$TMP_LAUNCH_ROOT/rawguard.XXXXXX")
  shim="$tmp/raw-guard"
  realbin="$tmp/realbin"
  fm_launch_write_raw_guard "$shim" || fail "fm_launch_write_raw_guard failed"
  for b in cursor-agent cursor agy; do
    assert_present "$shim/$b" "guard shim for $b was not written"
    [ -x "$shim/$b" ] || fail "guard shim for $b is not executable"
  done
  mkdir -p "$realbin"
  execlog="$tmp/executed.log"
  for b in agy cursor-agent cursor; do
    printf '#!/usr/bin/env bash\nprintf "REAL_%s_RAN\\n" >> %q\n' "$b" "$execlog" > "$realbin/$b"
    chmod +x "$realbin/$b"
  done

  # <label>|<shell command the raw launch could expand to>
  local label cmd n=0
  while IFS='|' read -r label cmd; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    : > "$execlog"
    PATH="$shim:$realbin:$PATH" bash -c "$cmd" >/dev/null 2>&1
    rc=$?
    [ ! -s "$execlog" ] || fail "B1 bypass [$label]: the real restricted binary EXECUTED ($(cat "$execlog"))"
    [ "$rc" -ne 0 ] || fail "B1 bypass [$label]: the shim did not refuse (exit 0)"
  done <<'ROWS'
quote-concat agy|ag"y" --dangerously-skip-permissions
quote-concat cursor-agent|cur"sor-agent" --trust --force
eval + quote-concat agy|eval ag"y" --dangerously-skip-permissions
brace agy|a{gy,} --dangerously-skip-permissions
brace cursor-agent|cur{sor-agent,} --trust --force
process substitution agy|source <(printf %b "\141\147\171 --x")
alias expansion agy|shopt -s expand_aliases; alias a=agy; a --x
wrapper via PATH agy|agy --x
plain cursor-agent|cursor-agent --trust
ROWS
  [ "$n" -ge 9 ] || fail "expected all bypass rows to run, ran $n"

  # Accepted residuals for this PATH shim are an absolute-path invocation, a PATH
  # reset that drops the guard, and `rm -rf` of the predictable guard dir before
  # invoking. The raw command is firstmate-authored, so code able to remove the
  # guard already has full same-user execution and can reach the CLI by other
  # paths. This test therefore treats the shim as accident-prevention rather than
  # a security boundary and does not claim to intercept those deliberate actions.

  # A legitimate, non-restricted raw command is unaffected by the guard.
  : > "$execlog"
  PATH="$shim:$realbin:$PATH" bash -c 'echo ok >/dev/null && exit 0' \
    || fail "the raw guard must not interfere with a non-cursor/agy command"

  rm -rf "$tmp"
  pass "the exec-time raw guard blocks PATH-resolved cursor/agy spellings, with absolute-path, PATH-reset, and guard-removal circumvention documented as accepted residuals"
}

test_render_substitutes_operational_input_and_pi_env
test_render_rejects_unknown_placeholder
test_cursor_template
test_agy_template
test_raw_restricted_harness_resolution
test_raw_restricted_harness_shell_wrappers
test_raw_restricted_harness_variable_indirection
test_raw_guard_intercepts_every_bypass_spelling
test_existing_templates_unchanged
test_unknown_harness_returns_nonzero
test_cursor_model_passthrough
test_agy_model_flag
test_model_flag_empty_and_default
test_cursor_has_no_effort_flag
test_agy_effort_vocabulary
test_existing_effort_flags_unchanged

echo "# all fm-launch-lib tests passed"
