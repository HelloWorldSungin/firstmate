---
name: tool-updates
description: >-
  Check the fleet toolchain for available updates, judge which are worth taking, and prepare an attended upgrade plan.
  Use when the captain says "check tool updates", "are our tools current", "update firstmate's tools", or asks what a tool upgrade would actually require.
  Reports through bin/fm-tool-status.sh, records version decisions in the home-local tool-decision ledger, and never upgrades anything itself.
user-invocable: true
metadata:
  internal: true
---

# tool-updates

Keep this fleet's toolchain current without ever upgrading the machine out from under the running fleet.
This skill reports, evaluates, records decisions, and prepares an attended upgrade plan.
It never installs, upgrades, uninstalls, or runs a `setup hooks` command, never restarts the shared no-mistakes daemon, never restarts herdr, and never edits a version floor.
Firstmate runs on this machine; an upgrade here is surgery on the running system, and performing it is the captain's call, not this skill's.

## Report

Run `"$FM_ROOT/bin/fm-tool-status.sh"` (read-only; it only runs `<tool> --version`, `npm view`, `gh-axi release list`, and reads `https://herdr.dev/latest.json`).
That script is the single owner of version reading: read its output, never reimplement installed-version or latest-version lookups here.

Reading its report:

- `current` needs no action.
- `behind` is only a fact, not a recommendation; the Evaluate section below decides whether it is worth taking.
- `could-not-verify (...)` names the command that failed; say so in the answer rather than silently skipping the tool or assuming installed equals latest.
- The `latest` column is always the latest GA release; a `pre-releases up to X excluded` note means newer pre-releases exist and were deliberately not counted.
- The `floor` column is read live from the three floor-owning files; `below floor` means bootstrap will report that tool `MISSING:` at session start.
- `chrome-devtools-axi` shows `none` for its floor by design, not by oversight.

## Evaluate

Judge each available update against how this fleet actually uses the tool, never against the release notes' own framing.
Consult the ledger (below) before re-investigating anything: an entry that already rejected an upgrade with evidence should not be re-researched until its stated re-evaluation condition arrives (a release containing code, a new credential source, a schema change).
For each candidate, weigh:

- Does firstmate parse this tool's output (`quota-axi --json` at every dispatch, `tasks-axi list` at session start, `chrome-devtools-axi` eval results)? Then an output-format change is a real hazard, not cosmetic.
- Does this tool host firstmate's own runtime (`herdr` is this home's multiplexer backend; `no-mistakes` is one shared daemon for every lane and home)? Then the upgrade procedure itself is the risk.
- Does this fleet call this tool at all (a tool with zero call sites, like `gnhf`, is evaluated as "not worth it" by default)?
- Is the "update" actually a pre-release, a preview build, or a release with zero relevant code (a CI-workflow change)? Then the right verdict is "available but not worth taking", and that verdict belongs in the ledger.

## The tool-decision ledger

Record every version decision - taken, pending, or held - in `$FM_HOME/data/tool-decisions.md` at the moment the decision is made, as a step in this skill's own procedure.
A ledger that depends on someone remembering to update it goes stale, and a stale ledger reads authoritative while being wrong.

The ledger is home-local private state (tool versions are per-install; one home's state is not every home's), created lazily on first write, never committed.
Record decisions and dated observations only, never a mirror of current state: live versions always come from the checker.
Curate it like `data/learnings.md`: terse, evidence-backed, dated, rewritten and pruned rather than appended forever.

Entry shape - one block per decision:

    ## YYYY-MM-DD <tool>
    - decision: <from X to Y | held at X | upgrade pending to Y>
    - why: <one sentence someone can act on later>
    - verified: <the commands, sources, or checks that back the claim>
    - not taken: <what was deliberately skipped, and when to re-evaluate>

When writing to a home whose ledger does not yet exist, create it by recording the decisions this fleet already owes from 2026-08-14 (verified by two surveys: `local:firstmate/firstmate-bc8432f7/task/fm-tool-updates-axi-family` and `.../fm-tool-updates-pipeline`):

    ## 2026-08-14 treehouse
    - decision: held at v2.1.0 (v2.1.1 available)
    - why: v2.1.1 is a CI-workflow change with zero CLI or binary code; the every-run upgrade nag is noise.
    - verified: kunchenguid/treehouse v2.1.1 release notes; the only commit is a CI suppression (da7eda2).
    - not taken: v2.1.1; re-evaluate on the next release that contains code.

    ## 2026-08-14 herdr
    - decision: confirmed current at 0.8.0
    - why: both sources agree on 0.8.0; everything newer is a dated preview build.
    - verified: https://herdr.dev/latest.json and the herdrdev/herdr releases list.
    - not taken: preview builds; a queued upgrade item was closed on this.

    ## 2026-08-14 gnhf
    - decision: held at 0.1.43 (0.1.44 available)
    - why: firstmate has no gnhf call site at all; it appears only in an evaluation-set document.
    - verified: repo-wide grep of bin/, .agents/, docs/, AGENTS.md finds zero invocations.
    - not taken: 0.1.44; re-evaluate only if external tooling first requires it.

    ## 2026-08-14 no-mistakes
    - decision: upgrade pending to v1.48.0, deliberately NOT v1.51.0
    - why: v1.49.0 through v1.51.0 are all pre-releases; the GA is v1.48.0.
    - verified: the kunchenguid/no-mistakes releases list marks all three newer tags pre-release.
    - not taken: v1.49.0-v1.51.0; the upgrade needs a window with no active pipeline runs (see safety rules).

    ## 2026-08-14 quota-axi
    - decision: upgrade pending to 0.1.28 (from 0.1.21)
    - why: Cursor coverage widening; but on this Linux host it may not improve, because the new credential path is a macOS Keychain facility and this host's editor state database does not exist.
    - verified: changelogs for 0.1.22-0.1.28; quota-axi auth --json showing cursor sourcesTried=state-vscdb and no such database on this host.
    - not taken: floor bump to 0.1.28; floors follow installs and this host still runs 0.1.21.

## Safety rules

Each rule below encodes a real failure this fleet hit or came within one command of hitting; none is a style preference.

1. **Never raise a version floor above what the machines actually have installed.**
   A floor turns a below-floor home into a `MISSING:` diagnostic at session start and disables dispatch-profile resolution.
   Floor bumps follow installs, never lead them, and land as a separate tracked change, not inside this skill.
2. **Never restart the shared no-mistakes daemon casually.**
   One instance serves every lane and every home; restarting it kills other lanes' in-flight pipeline runs.
   A no-mistakes upgrade requires a window with no active runs anywhere.
3. **herdr must be upgraded from outside a herdr session.**
   It replaces the running multiplexer and would terminate every active pane and in-flight worker.
   This home's runtime backend is herdr.
4. **Verify a dependency's target actually exists before recommending its install.**
   Example: a survey once recommended installing `sqlite3` to unlock Cursor quota readings, but `/home/sungin/.config/Cursor/User/globalStorage/state.vscdb` does not exist on this host - this box runs the Cursor CLI, not the editor - so the install would have moved one error message to a different error message.
   Check the target exists; make that part of the plan, not a thing someone remembers.
5. **Treat an output-format change as a real hazard.**
   Firstmate parses several of these tools, and firstmate's own agent reads `quota-axi --json` at every dispatch.
   Snapshot the parsed output before and after an upgrade and diff it; never assume compatibility.
6. **Note when a tool's own upgrade nag is not worth taking.**
   A nag on every run is not evidence of value (see the treehouse entry above).
   Prefer an explicit "available but not worth it" ledger entry over treating every nag as an action.

## Drive an attended upgrade

Present the plan to the captain; the captain runs it.

The plan, per tool: from-version and to-version, the why (from Evaluate), the exact install command from the tool's own distribution channel, the safety rule(s) that apply, the verification steps (checker re-run, parsed-output snapshot diff where rule 5 applies), and the rollback consideration.
When the captain approves and performs the upgrade, this skill's remaining job is: re-run the checker to confirm the new state, then write the ledger entry, then - if appropriate - propose the floor bump as a separate tracked change for a future session, never in the same breath as the install.

On-demand is the right shape for this whole mechanism; do not add upgrade-available noise to session start.
