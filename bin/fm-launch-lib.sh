#!/usr/bin/env bash
# bin/fm-launch-lib.sh - the ONE owner of crewmate/secondmate LAUNCH-COMMAND
# construction: the per-harness launch template plus the per-harness --model and
# effort flag renderers. Sourced by bin/fm-spawn.sh (which owns the surrounding
# spawn machinery: worktree isolation, backend container creation, turn-end hook
# installation, and metadata). Split into its own file so the pure
# string-construction logic is unit-testable without driving a full spawn
# (tests/fm-launch-lib.test.sh) while bin/fm-spawn.sh stays the owner of the
# stateful launch sequence.
#
# The KNOWLEDGE half of each adapter (busy signature, exit command, dialogs,
# quirks, verified versions) lives in the harness-adapters skill; this file owns
# only the exact launch string. Placeholders (__MODELFLAG__, __EFFORTFLAG__,
# __BRIEF__, __TURNEND__, __PIEXT__, __PITURNEND__, __PIWATCH__, __OPINPUT__ - the
# canonical operational-input encoder that every template pipes the brief through,
# origin/main #909 - and __PIBRIEFENV__ - the Pi unchanged-brief env assignment)
# are substituted by bin/fm-spawn.sh after this template is chosen; see its header.
#
# cursor and agy are CREW-ONLY, herdr-ONLY adapters (captain-approved divergence,
# data/captain.md; verification data/cursor-agy-verify/report.md). They are never
# a primary runtime and never a secondmate launcher, and firstmate refuses them
# on any non-herdr backend. bin/fm-spawn.sh enforces both gates before launch;
# the templates below are the ship/scout launch string only. Harness token
# `cursor` launches the `cursor-agent` CLI; `agy` launches the `agy` CLI.

# fm_launch_shell_quote: single-quote <text> for safe reuse inside a launch
# command that is itself sent to the crewmate's pane shell.
fm_launch_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_launch_restricted_harness_of_word: map one command word (an executable path
# or name) to the crew-only restricted harness it launches, or nothing.
# cursor-agent and cursor -> cursor; agy -> agy.
fm_launch_restricted_harness_of_word() {  # <word>
  case "$(basename -- "${1:-}")" in
    cursor-agent|cursor) printf 'cursor' ;;
    agy) printf 'agy' ;;
  esac
}

# fm_launch_raw_restricted_harness: given a RAW launch command string (the
# unverified-adapter escape hatch), decide whether firstmate must REFUSE it
# because it could launch the crew-only cursor/agy CLIs outside their canonical
# --harness path. Prints one of:
#   cursor | agy - a restricted executable basename is present (literal case).
#   unresolved   - the command uses shell INDIRECTION ($ expansion, backtick or
#                  $() command substitution, or the `eval` builtin) that could
#                  resolve to cursor-agent/agy but cannot be cleared statically.
#   <empty>      - safe to allow through the raw hatch.
#
# WHY the indirection rule: the raw command is ultimately executed by the
# crewmate PANE's shell, so `AGY=agy bash -lc '$AGY ...'`, `bash -lc 'x=agy;
# eval "$x ..."'`, backticks, `$(...)`, and split-token concatenation (`$a$g`)
# can all launch a restricted executable that a basename scan can never see. So
# any unresolved shell expansion makes the command unverifiable, and firstmate
# refuses it. This over-approximates (a raw command that merely uses `$FOO` for
# an unrelated reason is also refused), which is acceptable: the raw hatch exists
# for UNVERIFIED adapters, cursor/agy are verified with a canonical --harness path
# (that also installs the trust seed and native supervision), and a refusal here
# only sends the operator to that path or to an expansion-free spelling.
fm_launch_raw_restricted_harness() {  # <raw-command> -> cursor|agy|unresolved|<empty>
  local cmd=$1 word found normalized
  # shellcheck disable=SC2086  # deliberate word-splitting of the raw command string
  set -- $cmd
  # Skip leading VAR=val assignments.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_][A-Za-z0-9_]*=*) shift ;;
      *) break ;;
    esac
  done
  # Resolve an `env` wrapper to the command it runs.
  if [ "$(basename -- "${1:-}")" = env ]; then
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        [A-Za-z_][A-Za-z0-9_]*=*) shift ;;   # env NAME=val
        -u) shift 2 2>/dev/null || shift ;;   # env -u NAME
        --unset=*) shift ;;
        --) shift; break ;;
        -*) shift ;;                          # any other env option
        *) break ;;
      esac
    done
  fi
  found=$(fm_launch_restricted_harness_of_word "${1:-}")
  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
  # Literal-basename backstop: replace shell quote characters and command
  # separators with spaces so a quoted/wrapped invocation splits into plain
  # tokens, then scan every token's basename for a restricted executable. Catches
  # `bash -lc 'agy ...'` (whose raw token is "'agy", not "agy") and similar.
  normalized=$(printf '%s' "$cmd" | tr $'\047"\140;&|(){}<>\n\t' '              ')
  # shellcheck disable=SC2086  # deliberate word-splitting of the normalized string
  set -- $normalized
  for word in "$@"; do
    case "$word" in [A-Za-z_][A-Za-z0-9_]*=*) continue ;; esac
    found=$(fm_launch_restricted_harness_of_word "$word")
    [ -z "$found" ] || { printf '%s' "$found"; return 0; }
  done
  # Indirection backstop: a `$` (variable or $() command substitution) or a
  # backtick means the pane shell could expand a restricted executable name the
  # literal scan above cannot see (`$AGY`, `$(...)`, `$a$g`, `eval "$x"`). A bare
  # `eval agy` needs no `$` but carries the literal `agy` the scan already caught,
  # so these two characters cover every real indirection bypass.
  #
  # NOTE: this string classifier is only the EARLY, defense-in-depth layer. The
  # shell is Turing-complete, so quote concatenation (`ag"y"`), brace expansion
  # (`a{gy,}`), alias expansion, and generated process substitution can all
  # assemble a restricted command that no static scan can model. The robust
  # primary B1 defense is the exec-time PATH shim below
  # (fm_launch_write_raw_guard), installed into the raw-command pane by
  # bin/fm-spawn.sh; it catches ANY spelling that actually resolves the binary
  # through PATH, including a wrapper script that internally execs it.
  case "$cmd" in
    *'$'*|*'`'*) printf 'unresolved'; return 0 ;;
  esac
}

# fm_launch_write_raw_guard: write executable guard shims named `cursor-agent`,
# `cursor`, and `agy` into <dir>. bin/fm-spawn.sh prepends <dir> to the PATH of a
# RAW launch command's pane, making these shims the EXEC-TIME gate for B1: when
# any shell spelling in the raw command resolves one of those restricted binaries
# through PATH, the shim runs instead of the real CLI, refuses loudly, and exits
# non-zero, so cursor/agy never launch outside the sanctioned `--harness` path
# (which does NOT use this guard and reaches the real binary directly). Because
# the shell performs the expansion before exec, this uniformly defeats quote
# concatenation, brace/alias/process-substitution expansion, and even a wrapper
# script that internally execs the binary - none of which a launch-string scan
# can model.
#
# Residual limitation (documented, out of scope for a PATH shim): an ABSOLUTE-path
# invocation, a raw command that first resets PATH to drop this dir, or a raw
# command that removes this predictable guard dir before invoking the binary
# bypasses the shim. The raw command is firstmate-authored rather than
# attacker-supplied, so same-user code able to remove the guard already has full
# execution and can reach the CLI by other paths. This guard prevents accidents;
# it is not a security boundary. Closing these deliberate circumventions would
# require execve-level interception (LD_PRELOAD/seccomp) that is platform-specific
# and disproportionate.
fm_launch_write_raw_guard() {  # <dir>
  local dir=$1 name
  [ -n "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  for name in cursor-agent cursor agy; do
    cat > "$dir/$name" <<'SHIM'
#!/usr/bin/env bash
# firstmate raw-launch guard shim (bin/fm-launch-lib.sh fm_launch_write_raw_guard).
# Reached only when a raw launch command resolved a crew-only cursor/agy binary
# through PATH; the sanctioned --harness path never routes through here.
prog=$(basename -- "$0")
case "$prog" in
  cursor-agent|cursor) canon=cursor ;;
  agy) canon=agy ;;
  *) canon=$prog ;;
esac
printf 'firstmate: refusing to run "%s" from a raw launch command - %s is a crew-only, herdr-only adapter that must be launched via `--harness %s` so firstmate can seed its workspace trust and supervise it (harness-adapters skill). Aborting.\n' "$prog" "$canon" "$canon" >&2
exit 127
SHIM
    chmod +x "$dir/$name" || return 1
  done
}

# fm_launch_template: print the verified launch command for <harness> (<kind>
# defaults to ship). Returns 1 for an unknown harness so the caller can fall
# back to the raw-launch-command escape hatch.
fm_launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(__OPINPUT__ ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' '__PIBRIEFENV__ pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' '__PIBRIEFENV__ pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed by fm-spawn (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # cursor (Cursor Agent CLI, harness token `cursor`, binary `cursor-agent`):
    # a positional prompt starts the supervised interactive session. --trust
    # bypasses the interactive workspace-trust modal (verified: the modal blocks
    # an unattended launch and --force does NOT cover it); --force (alias --yolo)
    # auto-approves every command, the equivalent of claude's
    # --dangerously-skip-permissions. cursor has NO standalone effort flag: effort
    # is encoded inside the parameterized model string (e.g.
    # 'composer-2.5[effort=high]'), which --model accepts verbatim, so the template
    # carries __MODELFLAG__ but no __EFFORTFLAG__. Turn-end is the watcher's
    # debounced native-completion detector (fm-watch.sh maybe_native_turnend), so
    # no launch-time turn-end hook is installed.
    cursor) printf '%s' 'cursor-agent --trust --force __MODELFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # agy (Antigravity CLI, Gemini): --prompt-interactive takes the initial prompt
    # as its value and keeps the session interactive for supervised steering.
    # --dangerously-skip-permissions auto-approves tool use. Workspace trust is a
    # SEPARATE gate that --dangerously-skip-permissions does NOT cover (verified);
    # fm-spawn pre-seeds the exact worktree path into agy's global trustedWorkspaces
    # before launch (bin/fm-agy-trust-lib.sh). --effort accepts only low|medium|high
    # (agy --help). Turn-end is the watcher's debounced native-completion detector,
    # so no launch-time hook is installed.
    agy) printf '%s' 'agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--prompt-interactive "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

# fm_launch_model_flag: render the --model flag for <harness> given <model>, or
# nothing when the model is empty/default or the harness takes no verified model
# flag. The model string is passed through verbatim (shell-quoted), so cursor's
# parameterized form 'composer-2.5[effort=high]' reaches --model intact.
fm_launch_model_flag() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok|cursor|agy)
      printf -- '--model %s ' "$(fm_launch_shell_quote "$model")"
      ;;
  esac
}

# fm_launch_effort_flag: render the per-harness effort flag for <harness> given
# <effort>, or nothing when the effort is empty/default, the harness has no
# effort flag, or the level is outside that harness's verified vocabulary.
fm_launch_effort_flag() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(fm_launch_shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    agy)
      # agy --help advertises --effort low|medium|high only; omit xhigh/max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high) printf -- '--effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    # cursor has no standalone effort flag: effort is encoded in the parameterized
    # model string (see fm_launch_template), so it is never rendered here.
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
  esac
}
