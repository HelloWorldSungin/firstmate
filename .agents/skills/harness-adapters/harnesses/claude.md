## claude (VERIFIED; busy-state hooks live-verified 2026-07-28 on Claude Code 2.1.220)

| Fact | Value |
|---|---|
| Busy state | Owned lifecycle hooks: `UserPromptSubmit` opens a turn, while `Stop`, `StopFailure`, and `SessionEnd` close it; because Claude fires no hook for a manual interrupt, `bin/fm-control.sh interrupt` reports only delivered keys and the verified endpoint or live agent, publishes no idle event, makes no cancellation claim, and leaves adapter-observed state unchanged, so a mid-turn worker typically remains busy via `claude-hook`. |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation, accepted by Enter or by the choice the dialog names.
No launch flag suppresses it, so it is a post-launch step; the shared head's "Trust and first-launch dialogs" owns the peek-and-accept procedure.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
Claude's ghost text is dim/faint SGR 2, which the shared composer classifier already strips, so a pane the env var cannot reach - including the captain's own firstmate composer that away-mode reads - still classifies correctly as defense in depth.

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, Claude Code 2.1.204; Stop-owned auto-arm revalidated 2026-07-24, Claude Code 2.1.219).**
This is separate from the per-task crewmate turn-end hook the shared head assigns to `bin/fm-spawn.sh` (that one just `touch`es a marker file in a task's own `.claude/settings.local.json`).
The firstmate PRIMARY's own `.claude/settings.json` registers two Stop hooks: `bin/fm-turnend-guard.sh --claude` and the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` (`asyncRewake: true`, `timeout: 28800`), and exiting the guard with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows ANY stop-hook-driven continuation, including `asyncRewake` rewakes; the primary guard therefore ignores it in `--claude` mode and uses the cooperative claim/epoch check plus a bounded re-block budget instead, while the codex-mode default still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked commands anchored through `"$CLAUDE_PROJECT_DIR"/bin/...` and see `docs/turnend-guard.md` for the verified Stop-hook details.
Claude Code's primary watcher protocol is Stop-owned: the auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake; the model drains and handles wakes but never runs a routine re-arm command.

