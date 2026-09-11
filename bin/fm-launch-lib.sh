#!/usr/bin/env bash
# bin/fm-launch-lib.sh - the ONE owner of crewmate/secondmate LAUNCH-COMMAND
# construction: the per-harness launch template plus the per-harness --model and
# effort flag renderers. Sourced by bin/fm-spawn.sh (which owns the surrounding
# spawn machinery: worktree isolation, backend container creation, non-template
# turn-end hook installation, workspace-trust orchestration, and metadata).
# Split into its own file so the pure
# string-construction logic is unit-testable without driving a full spawn
# (tests/fm-launch-lib.test.sh) while bin/fm-spawn.sh stays the owner of the
# stateful launch sequence.
#
# The KNOWLEDGE half of each adapter (busy signature, exit command, dialogs,
# quirks, verified versions) lives in the harness-adapters skill; this file owns
# only the exact launch string. fm_launch_render below is the one owner that
# substitutes placeholders (__MODELFLAG__, __EFFORTFLAG__, __BRIEF__,
# __TURNEND__, __PIEXT__, __PITURNEND__, __PIWATCH__, and __OPINPUT__ - the
# canonical operational-input encoder that every template pipes the brief
# through, #909) after a template is chosen.
#
# agy is a CREW-ONLY, herdr-ONLY adapter (captain-approved divergence,
# data/captain.md; verification data/cursor-agy-verify/report.md). It is never
# a primary runtime and never a secondmate launcher, and firstmate refuses it
# on any non-herdr backend. bin/fm-spawn.sh enforces both gates before launch;
# the agy template below is the ship/design/scout launch string only.
# Harness token `agy` launches the `agy` CLI.

# fm_launch_shell_quote: single-quote <text> for safe reuse inside a launch
# command that is itself sent to the crewmate's pane shell.
fm_launch_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_launch_render: substitute every launch-template placeholder and print the
# rendered command. After the nine positional bindings, an optional
# <allow-unresolved> flag may be followed by placeholder/value pairs for
# state-derived adapter paths. Every value is substituted only once. The flag is for
# the raw-command escape hatch, whose input is not a verified template. Every
# template caller fails loudly if a future placeholder is added without also
# being rendered here.
#
# Rendering is SINGLE-PASS: the template is walked once and each recognized
# placeholder is replaced as it is reached, so a substituted value is never
# rescanned. That matters because the values are paths chosen by the operator,
# not by this repository: a worktree, brief, or extension path may legitimately
# contain a `__NAME__` segment, and a multi-pass renderer would either mangle it
# or refuse the launch outright.
#
# Unbound legacy Pi/Cursor/worktree placeholders retain their compatibility
# pass-through. Spawn supplies their concrete values as explicit pairs so
# adapter paths containing placeholder-like text are never rescanned.
fm_launch_render() {  # <template> <model-flag> <effort-flag> <brief> <turnend> <pi-ext> <pi-turnend> <pi-watch> <op-input> [<allow-unresolved> [<placeholder> <value>...]]
  local launch model_flag effort_flag brief turnend pi_ext pi_turnend pi_watch
  local op_input allow_unresolved token prefix out rest i found
  local -a extra_names extra_values
  extra_names=(); extra_values=()
  if [ "$#" -lt 9 ] || { [ "$#" -gt 10 ] && [ "$(( ($# - 10) % 2 ))" -ne 0 ]; }; then
    printf 'firstmate: fm_launch_render expected 9 arguments, optional raw flag and placeholder/value pairs, got %s\n' "$#" >&2
    return 1
  fi
  launch=$1
  model_flag=$2
  effort_flag=$3
  brief=$4
  turnend=$5
  pi_ext=$6
  pi_turnend=$7
  pi_watch=$8
  op_input=$9
  allow_unresolved=${10:-0}
  if [ "$#" -ge 10 ]; then shift 10; else shift 9; fi
  while [ "$#" -gt 0 ]; do
    if ! [[ $1 =~ ^__[A-Z][A-Z0-9]*(_[A-Z0-9]+)*__$ ]]; then
      printf 'firstmate: invalid launch binding %s\n' "$1" >&2
      return 1
    fi
    for ((i=0; i < ${#extra_names[@]}; i++)); do
      if [ "${extra_names[$i]}" = "$1" ]; then
        printf 'firstmate: duplicate launch binding %s\n' "$1" >&2
        return 1
      fi
    done
    extra_names+=("$1"); extra_values+=("$2")
    shift 2
  done

  out=""
  rest=$launch
  # The name class excludes a trailing underscore run so two adjacent
  # placeholders (`__MODELFLAG____EFFORTFLAG__`) match as two tokens rather than
  # being swallowed into one unrecognized name.
  while [[ $rest =~ __[A-Z][A-Z0-9]*(_[A-Z0-9]+)*__ ]]; do
    token=${BASH_REMATCH[0]}
    prefix=${rest%%"$token"*}
    rest=${rest#"$prefix$token"}
    out=$out$prefix
    found=0
    for ((i=0; i < ${#extra_names[@]}; i++)); do
      if [ "${extra_names[$i]}" = "$token" ]; then
        out=$out${extra_values[$i]}
        found=1
        break
      fi
    done
    [ "$found" = 0 ] || continue
    case "$token" in
      __MODELFLAG__)  out=$out$model_flag ;;
      __EFFORTFLAG__) out=$out$effort_flag ;;
      __BRIEF__)      out=$out$brief ;;
      __TURNEND__)    out=$out$turnend ;;
      __PIEXT__)      out=$out$pi_ext ;;
      __PITURNEND__)  out=$out$pi_turnend ;;
      __PIWATCH__)    out=$out$pi_watch ;;
      __OPINPUT__)    out=$out$op_input ;;
      __PIBIN__|__PITUIMODE__|__CURSORBIN__|__WORKTREE__) out=$out$token ;;
      *)
        if [ "$allow_unresolved" = 1 ]; then
          out=$out$token
        else
          printf 'firstmate: unresolved launch placeholder %s\n' "$token" >&2
          return 1
        fi
        ;;
    esac
  done
  printf '%s' "$out$rest"
}

# fm_launch_restricted_harness_of_word: map one command word (an executable path
# or name) to the crew-only restricted harness it launches, or nothing.
# agy -> agy. cursor is deliberately absent: it became an ordinary verified
# harness with no crew-only or backend gate, so a raw cursor launch bypasses no
# gate and needs no refusal.
fm_launch_restricted_harness_of_word() {  # <word>
  case "$(basename -- "${1:-}")" in
    agy) printf 'agy' ;;
  esac
}

# fm_launch_raw_restricted_harness: given a RAW launch command string (the
# unverified-adapter escape hatch), decide whether firstmate must REFUSE it
# because it could launch the crew-only agy CLI outside its canonical --harness
# path. Prints one of:
#   agy        - the restricted executable basename is present (literal case).
#   unresolved - the command uses shell INDIRECTION ($ expansion, backtick or
#                $() command substitution, or the `eval` builtin) that could
#                resolve to agy but cannot be cleared statically.
#   <empty>    - safe to allow through the raw hatch.
#
# WHY the indirection rule: the raw command is ultimately executed by the
# crewmate PANE's shell, so `AGY=agy bash -lc '$AGY ...'`, `bash -lc 'x=agy;
# eval "$x ..."'`, backticks, `$(...)`, and split-token concatenation (`$a$g`)
# can all launch a restricted executable that a basename scan can never see. So
# any unresolved shell expansion makes the command unverifiable, and firstmate
# refuses it. This over-approximates (a raw command that merely uses `$FOO` for
# an unrelated reason is also refused), which is acceptable: the raw hatch exists
# for UNVERIFIED adapters, agy is verified with a canonical --harness path (that
# also installs the trust seed and native supervision), and a refusal here only
# sends the operator to that path or to an expansion-free spelling.
fm_launch_raw_restricted_harness() {  # <raw-command> -> agy|unresolved|<empty>
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

# fm_launch_write_raw_guard: write an executable guard shim named `agy` into
# <dir>. bin/fm-spawn.sh prepends <dir> to the PATH of a
# RAW launch command's pane, making this shim the EXEC-TIME gate for B1: when
# any shell spelling in the raw command resolves that restricted binary
# through PATH, the shim runs instead of the real CLI, refuses loudly, and exits
# non-zero, so agy never launches outside the sanctioned `--harness` path
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
  local dir=$1
  [ -n "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  cat > "$dir/agy" <<'SHIM'
#!/usr/bin/env bash
# firstmate raw-launch guard shim (bin/fm-launch-lib.sh fm_launch_write_raw_guard).
# Reached only when a raw launch command resolved the crew-only agy binary
# through PATH; the sanctioned --harness path never routes through here.
prog=$(basename -- "$0")
case "$prog" in
  agy) canon=agy ;;
  *) canon=$prog ;;
esac
printf 'firstmate: refusing to run "%s" from a raw launch command - %s is a crew-only, herdr-only adapter that must be launched via `--harness %s` so firstmate can seed its workspace trust and supervise it (harness-adapters skill). Aborting.\n' "$prog" "$canon" "$canon" >&2
exit 127
SHIM
  chmod +x "$dir/agy" || return 1
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
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\'' __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # pi and pi-signed share one template shape. __PIBIN__ is the concrete
    # executable fm-spawn resolves from PATH for the exact harness token, so
    # pi-signed never silently falls back to pi, and __PITUIMODE__ carries the
    # regular-TUI override only when that executable advertises the flag.
    pi|pi-signed)
      printf '%s' '__PIBIN____PITUIMODE__'
      if [ "$kind" = secondmate ]; then
        printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed by fm-spawn (global hook +
    # per-task pointer), so the template is identical for ship/design/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Kimi Code rejects a positional prompt, so it launches bare and receives only
    # an absolute brief pointer after fm-spawn's TUI readiness gate. Its turn-end
    # signal is a globally configured Stop hook plus a guarded per-task worktree
    # token, so no launch placeholder belongs here. __KIMIBIN__ is resolved by
    # fm-spawn before rendering, because the binary lookup is spawn-time state.
    kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;
    # Muse is crewmate/scout only. Its default build has no usable hook surface,
    # so fm-spawn binds its durable session log rather than adding a turn-end
    # placeholder here. The foreign-context kill switch keeps operator-private
    # Claude rules out of Meta-hosted inference while preserving project rules.
    muse) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME=__MUSECONFIG__ XDG_DATA_HOME=__MUSEDATA__ MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on __MUSEBIN__ --yolo __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Cursor Agent CLI. --trust suppresses the workspace-trust prompt, which
    # --yolo does NOT cover and which would otherwise block every spawn, since
    # each task gets a fresh worktree path cursor has never seen. --yolo is the
    # --force alias whose TUI label is "Run Everything". --workspace pins the
    # exact worktree. -w/--worktree is deliberately never passed: it allocates a
    # SECOND worktree under ~/.cursor/worktrees and would break firstmate's
    # isolation contract. __CURSORBIN__ is resolved by fm-spawn through
    # fm_cursor_resolve_binary rather than named here, because `cursor` is not the
    # CLI (the installed names are cursor-agent and the legacy alias agent), and
    # the foreign primary markers are cleared so an inherited CLAUDECODE cannot
    # outrank cursor's own marker in a process that only reads the environment.
    # Cursor exposes no effort flag, so the shared effort axis is deliberately
    # omitted and stays in task metadata only.
    cursor) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_INVOKED_AS __CURSORBIN__ --trust --yolo __MODELFLAG__--workspace __WORKTREE__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # agy (Antigravity CLI, Gemini): --prompt-interactive takes the initial prompt
    # as its value and keeps the session interactive for supervised steering.
    # --dangerously-skip-permissions auto-approves tool use. Workspace trust is a
    # SEPARATE gate that --dangerously-skip-permissions does NOT cover (verified);
    # fm-spawn pre-seeds the exact worktree path into agy's global trustedWorkspaces
    # before launch (bin/fm-agy-trust-lib.sh). --effort accepts only low|medium|high
    # (agy --help). Turn-end notification is the watcher's debounced native-idle detector,
    # so no launch-time hook is installed.
    agy) printf '%s' 'agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--prompt-interactive "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # omp (Oh My Pi), a Pi fork. Same one-positional-brief, --model, --thinking,
    # and -e shape as Pi, verified on omp 18.1.11. The differences are all at
    # the launch boundary and documented in the header above: foreign markers
    # cleared (omp has none of its own, so an inherited CLAUDECODE would win),
    # FM_OMP_HARNESS=omp established for bin/fm-harness.sh, OMP_SKIP_SETUP=1
    # against the fresh-profile provider wizard, --auto-approve so no approval
    # prompt can park an unattended worker, the tracked posture overlay so a
    # captain-level plan, prewalk, or usage dialog cannot either, and --cwd
    # pinned to the worktree because omp's extension discovery is cwd-only. A
    # secondmate loads its two primary extensions by that discovery alone:
    # naming them with -e as well loads each twice (verified), doubling every
    # session_stop continuation.
    omp)
      printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 __OMPBIN__ --config __OMPWORKERCFG__ --auto-approve --cwd __WORKTREE__'
      if [ "$kind" = secondmate ]; then
        printf '%s' ' __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __OMPEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # gemini (Google Gemini CLI): a positional query starts the supervised
    # interactive session and auto-submits it, so the brief rides the launch
    # command exactly as it does for claude and grok (verified: a multi-line
    # brief submitted itself with no extra Enter, gemini-cli 0.58.0).
    # -y (--yolo) auto-approves every tool call, which an unattended crewmate
    # needs; the footer renders ` YOLO Ctrl+Y` while it is on and a WriteFile
    # was verified to land with no approval gate.
    # Every task worktree is a fresh path, so gemini refuses to start at all
    # without a trust control. GEMINI_CLI_TRUST_WORKSPACE=true - NOT
    # --skip-trust - is the one used, and the difference is load-bearing
    # rather than cosmetic: the CLI's refusal message offers the two as
    # equivalents, but a controlled A/B on one worktree (same config home,
    # same prompt) showed --skip-trust runs the turn while leaving PROJECT
    # configuration unloaded, so the project's own .agents/skills are never
    # discovered. A firstmate-repo task needs exactly those, so the workspace
    # is trusted.
    # GEMINI_CLI_SYSTEM_SETTINGS_PATH points gemini at the firstmate-owned
    # per-task settings file written below. It is deliberately NOT the
    # worktree's .gemini/settings.json: unlike claude's settings.local.json,
    # that path is the PROJECT's own committed settings file, so writing it
    # would clobber a project's configuration and removing it at teardown
    # would delete a tracked file. The system layer also makes the busy
    # contract independent of the trust decision above (its hooks were
    # verified firing under --skip-trust in an untrusted folder), and hook
    # arrays MERGE across settings layers rather than overriding, so a
    # project's own hooks still run alongside firstmate's.
    # The foreign primary markers are cleared for the same reason cursor
    # clears them: gemini does not clear an inherited CLAUDECODE, and
    # bin/fm-harness.sh must not read a gemini worker as its launcher.
    # gemini exposes no reasoning-effort flag (checked against 0.58.0
    # --help), so the shared effort axis is deliberately omitted here and
    # stays in task metadata only, per the record-and-omit contract.
    # Its turn-end and busy-state signals do NOT ride the launch command:
    # they are project hooks written into the worktree below.
    gemini) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_CLI_SYSTEM_SETTINGS_PATH=__GEMINISETTINGS__ gemini -y __MODELFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # rovo (Atlassian Rovo CLI): a positional brief is dead-on-arrival - rovo
    # loads, never enters a working state, and drops back to an idle shell within
    # about 10-15 seconds (confirmed live four times over a raw PTY and once under
    # real tmux with the exact send-keys shape below). So rovo launches BARE,
    # exactly like kimi, and receives an absolute brief pointer only after the TUI
    # readiness gate below. --disable-permission-checks/--yolo makes every file
    # CRUD operation and bash command run without confirmation; Atlassian-data and
    # user MCP-server tools still prompt per its own printed caveat, which crew and
    # scout tasks never touch. --startup-receipt is not used either: it requires
    # "prompt-free interactive mode", so it cannot gate a launch that will have a
    # message typed into it. rovo does NOT scrub an inherited
    # CLAUDECODE/CURSOR_AGENT/etc, so foreign primary markers are cleared here as
    # defense in depth alongside the marker-ordering fix in bin/fm-harness.sh
    # (issue #3517); CURSOR_AGENT/CURSOR_INVOKED_AS are cleared by the shared
    # outer wrap below, like every other non-cursor harness. rovo has no
    # turn-end hook (its eventHooks fire at tool granularity only, never
    # turn-end), so no launch placeholder for one exists.
    # __ROVOCONFIGOVERRIDE__ (not __EFFORTFLAG__) carries rovo's single
    # --config-override flag: it always grants allowedExternalPaths for this
    # task's home-side brief dir, steering inbox, and status file - the file
    # tool confinement that otherwise blocks the standard
    # instructions/steering/status/report loop (rovo's bash tool has no such
    # grant and stays confined to the worktree; the worker's own file tools do
    # respect the grant, confirmed live) - merged with agent.efficiencyLevel
    # when a supported effort is requested, since a second --config-override
    # would silently discard the first (confirmed live).
    rovo) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS __ROVOBIN__ run --yolo __MODELFLAG____ROVOCONFIGOVERRIDE__' ;;
    *) return 1 ;;
  esac
}

# fm_launch_model_flag: render the --model flag for <harness> given <model>, or
# nothing when the model is empty/default or the harness takes no verified model
# flag. The model string is passed through verbatim (shell-quoted), so cursor
# model strings or parameterized overrides reach --model intact.
fm_launch_model_flag() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|muse|cursor|agy|gemini|rovo|omp)
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
    pi|pi-signed|omp)
      # Pi and pi-signed 0.82.0 both accept the full shared effort vocabulary,
      # including max, through their --thinking flag.
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
    muse)
      case "$effort" in
        low|medium|high|xhigh) printf -- '--reasoning-effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
        max) printf -- '--reasoning-effort %s ' "$(fm_launch_shell_quote ultra)" ;;
      esac
      ;;
    # cursor has no effort flag at all: it encodes effort in model ids such as
    # cursor-grok-4.5-high, validated against `cursor-agent --list-models`. The
    # requested effort stays in task metadata and never reaches the launch.
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    # kimi likewise has no reasoning-effort flag; the requested axis stays in task
    # metadata but never reaches the launch command.
  esac
}

# Build Rovo's single JSON launch override from this task's canonical paths.
# Rovo permits file tools to read these paths; its shell stays worktree-confined.
# A second --config-override would discard the first, so supported effort and
# the mandatory external-path grant are composed together here.
fm_launch_rovo_config_override_flag() {  # <effort> <data-dir> <state-dir> <id>
  local effort=$1 data_dir=$2 state_dir=$3 id=$4 data_real state_real config_json
  data_real=$(CDPATH='' cd -- "$data_dir" && pwd -P) || return 1
  state_real=$(CDPATH='' cd -- "$state_dir" && pwd -P) || return 1
  config_json=$(jq -cn --arg effort "$effort" --arg data "$data_real" \
    --arg state "$state_real" --arg id "$id" '
    (if (["low","medium","high","max"] | index($effort)) != null
     then {agent:{efficiencyLevel:$effort}} else {} end)
    + {toolPermissions:{allowedExternalPaths:[$data+"/"+$id,
        $state+"/"+$id+".inbox",$state+"/"+$id+".status"]}}') || return 1
  printf -- '--config-override %s ' "$(fm_launch_shell_quote "$config_json")"
}
