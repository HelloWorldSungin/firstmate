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
# __BRIEF__, __TURNEND__, __PIEXT__, __PITURNEND__, __PIWATCH__) are substituted
# by bin/fm-spawn.sh after this template is chosen; see its header.
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
# unverified-adapter escape hatch), print the crew-only restricted harness
# (cursor|agy) it would actually launch, or nothing. It resolves the real
# executable through leading VAR=val assignments and an `env` wrapper (skipping
# env's own options and NAME=val prefixes), then, as a fail-closed backstop
# against wrapper spellings it does not model, also scans every remaining word.
# This closes the bypass where a raw `cursor-agent ...`, `env agy ...`, or
# `FOO=1 agy ...` command would otherwise slip past a token-only cursor/agy guard
# (the executable basename is `cursor-agent`/`env`, not `cursor`/`agy`).
fm_launch_raw_restricted_harness() {  # <raw-command>
  local cmd=$1 word found
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
  # Fail-closed backstop: any word (past assignments) whose basename is a
  # restricted executable name forces the guard, even through an unmodeled wrapper.
  # shellcheck disable=SC2086
  set -- $cmd
  for word in "$@"; do
    case "$word" in [A-Za-z_][A-Za-z0-9_]*=*) continue ;; esac
    found=$(fm_launch_restricted_harness_of_word "$word")
    [ -z "$found" ] || { printf '%s' "$found"; return 0; }
  done
}

# fm_launch_template: print the verified launch command for <harness> (<kind>
# defaults to ship). Returns 1 for an unknown harness so the caller can fall
# back to the raw-launch-command escape hatch.
fm_launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
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
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed by fm-spawn (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
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
    cursor) printf '%s' 'cursor-agent --trust --force __MODELFLAG__"$(cat __BRIEF__)"' ;;
    # agy (Antigravity CLI, Gemini): --prompt-interactive takes the initial prompt
    # as its value and keeps the session interactive for supervised steering.
    # --dangerously-skip-permissions auto-approves tool use. Workspace trust is a
    # SEPARATE gate that --dangerously-skip-permissions does NOT cover (verified);
    # fm-spawn pre-seeds the exact worktree path into agy's global trustedWorkspaces
    # before launch (bin/fm-agy-trust-lib.sh). --effort accepts only low|medium|high
    # (agy --help). Turn-end is the watcher's debounced native-completion detector,
    # so no launch-time hook is installed.
    agy) printf '%s' 'agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--prompt-interactive "$(cat __BRIEF__)"' ;;
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
