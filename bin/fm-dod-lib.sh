#!/usr/bin/env bash
# Single owner of a task's mode-specific "Definition of done" block and of the
# fragments it is rendered from. Sourced by bin/fm-brief.sh, which renders it into
# a generated ship or design brief, and by bin/fm-promote.sh, which renders it into
# the ship instructions a promoted scout receives. Both paths must hand the worker
# the same contract: a promoted no-mistakes worker that never received the ask-user
# escalation rule or the `--yes` ban is the exact delivery hole this single owner
# exists to close.
#
# Entry points:
#   fm_dod_fragments <ship|design> <task-branch> <paused-verb>
#            set the DOD_* fragment variables for that task kind.
#   fm_dod_fragments_continue_branch <mode> <ship|design> <push-refspec-quoted> <task-branch>
#            replace the fragments a --continue-branch task states differently.
#   fm_dod_render <no-mistakes|direct-PR|local-only>
#            print the block built from the current fragments, with no trailing
#            blank line.
#   fm_dod_block <no-mistakes|direct-PR|local-only> <task-id>
#            the default ship rendering for `fm/<task-id>`, which is what a
#            promoted scout receives.
# The caller validates the mode; an unknown mode is refused rather than silently
# rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# The no-mistakes handoff is the fork's canonical `blocked: implemented and
# committed, ready to validate` entry, which bin/fm-trigger-validation.sh resolves;
# a worker that reports `done:` instead never reaches firstmate's validation
# trigger, so that string is load-bearing rather than cosmetic.
# The declared-external-wait verb is bin/fm-classify-lib.sh's, so this library
# loads that owner when a caller has not already, rather than restating its
# default here where the two copies could drift.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

if [ -z "${FM_CLASSIFY_PAUSED_VERB_DEFAULT:-}" ]; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"
fi

fm_dod_fragments() {  # <ship|design> <task-branch> <paused-verb>
  local kind=$1 task_branch=$2 paused_verb=$3
  # Remembered for fm_dod_fragments_continue_branch, whose overrides restate the
  # same declared-wait verb without re-resolving it.
  FM_DOD_PAUSED_VERB=$paused_verb
  DOD_DIRECT='Delivery contract: mode=direct-PR'
  DOD_LOCAL='Delivery contract: mode=local-only'
  DOD_NO_MISTAKES='Delivery contract: mode=no-mistakes'
  DOD_DIRECT_INTRO='This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.'
  DOD_DIRECT_COMPLETE='The task is complete only when committed on your branch.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_DIRECT_HANDOFF='When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.'
  DOD_LOCAL_INTRO='This task ships **local-only**: no remote, no PR, no pipeline.'
  DOD_LOCAL_COMPLETE="The task is complete only when committed on your branch \`$task_branch\`. Do NOT push, do NOT open a PR, do NOT merge."
  DOD_LOCAL_HANDOFF="When it is implemented and committed, append \`done: ready in branch $task_branch\` to the status file and stop."
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_INTRO='This project ships **no-mistakes**: `done:` means the PR is open with its checks green.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_LOCAL='A clean local commit is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR {url} checks green`.'
  DOD_NO_MISTAKES_COMPLETE='The task is complete only when committed on your branch.'
  DOD_NO_MISTAKES_HANDOFF="When you believe implementation is complete, append \`blocked: implemented and committed, ready to validate\` and stop there; that handoff is a defined stopping point because firstmate must trigger validation before you run /no-mistakes - use \`blocked:\`, not \`$paused_verb:\`, which would defer recheck for an hour under away mode."
  DOD_NO_MISTAKES_DRIVE='You drive no-mistakes by responding to its gates, not by implementing fixes.'
  DOD_NO_MISTAKES_ACTIVE='Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_ASK='  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.'
  DOD_NO_MISTAKES_PARK="While you sit parked on a backgrounded \`axi run\` or \`axi respond\` call, rule 4's park-and-resume pairing applies: append \`$paused_verb:\` before you go idle and \`working:\` when the call returns."
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_DONE='After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.'
  [ "$kind" = design ] || return 0
  DOD_DIRECT_INTRO='This ADR ships **direct-PR**: you raise its PR yourself, without the no-mistakes pipeline.'
  DOD_DIRECT_COMPLETE='The ADR is ready only when committed on your branch.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_DIRECT_HANDOFF='When the ADR is complete and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.'
  DOD_LOCAL_INTRO='This ADR ships **local-only**: no remote, no PR, no pipeline.'
  DOD_LOCAL_COMPLETE="The ADR is ready only when committed on your branch \`$task_branch\`. Do NOT push, do NOT open a PR, do NOT merge."
  DOD_LOCAL_HANDOFF="When the ADR is complete and committed, append \`done: ready in branch $task_branch\` to the status file and stop."
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_INTRO='This ADR ships through **no-mistakes**: `done:` means the PR is open with its checks green.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_LOCAL='A clean local ADR commit is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR {url} checks green`.'
  DOD_NO_MISTAKES_COMPLETE='The ADR is ready for validation only when committed on your branch.'
  DOD_NO_MISTAKES_HANDOFF="When the ADR is complete and committed, append \`$paused_verb: ADR complete and committed, ready to validate\` and stop there; that handoff is a defined stopping point and a declared wait, and firstmate will then instruct you to run /no-mistakes to validate and ship the ADR PR."
  DOD_NO_MISTAKES_DRIVE='You drive no-mistakes by responding to its gates, not by applying fixes.'
  DOD_NO_MISTAKES_ACTIVE='Do not hand-edit, commit, or apply findings yourself while a run is active - the pipeline applies every fix.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_ASK='  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or apply the fix yourself.'
}

fm_dod_fragments_continue_branch() {  # <mode> <ship|design> <push-refspec> <task-branch>
  local mode=$1 kind=$2 push_refspec=$3 task_branch=$4
  case "$mode:$kind" in
    direct-PR:ship)
      DOD_DIRECT_INTRO='This task continues an existing PR through **direct-PR**, without the no-mistakes pipeline.'
      DOD_DIRECT_COMPLETE='The task is complete only when committed at detached HEAD.'
      DOD_DIRECT_HANDOFF="When it is implemented and committed, push with \`git push origin $push_refspec\`, use \`gh-axi\` to confirm the existing PR was updated, then append \`done: PR https://...\` with that PR's full URL to the status file and stop."
      ;;
    direct-PR:design)
      DOD_DIRECT_INTRO='This ADR continues an existing PR through **direct-PR**, without the no-mistakes pipeline.'
      DOD_DIRECT_COMPLETE='The ADR is ready only when committed at detached HEAD.'
      DOD_DIRECT_HANDOFF="When the ADR is complete and committed, push with \`git push origin $push_refspec\`, use \`gh-axi\` to confirm the existing PR was updated, then append \`done: PR https://...\` with that PR's full URL to the status file and stop."
      ;;
    local-only:ship)
      DOD_LOCAL_COMPLETE="The task is complete only when committed at detached HEAD and local branch \`$task_branch\` points to that commit. Do NOT push, do NOT open a PR, do NOT merge."
      ;;
    local-only:design)
      DOD_LOCAL_COMPLETE="The ADR is ready only when committed at detached HEAD and local branch \`$task_branch\` points to that commit. Do NOT push, do NOT open a PR, do NOT merge."
      ;;
    no-mistakes:ship)
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_INTRO='This task continues an existing PR through **no-mistakes**: `done:` means that PR is updated with checks green.'
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_LOCAL='A clean local commit or push is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR https://... checks green` using the existing PR full URL.'
      DOD_NO_MISTAKES_COMPLETE="The task is ready for validation only when committed at detached HEAD and pushed to the existing branch \`$task_branch\`."
      DOD_NO_MISTAKES_HANDOFF="When you believe implementation is complete, committed, and pushed to the existing branch, append \`blocked: implemented, committed, and pushed, ready to validate\` and stop there; that handoff is a defined stopping point because firstmate must trigger validation before you run /no-mistakes - use \`blocked:\`, not \`${FM_DOD_PAUSED_VERB}:\`, which would defer recheck for an hour under away mode."
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_DONE='After /no-mistakes reports CI green for the existing PR (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR https://... checks green` using that PR full URL and stop. You are finished.'
      ;;
    no-mistakes:design)
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_INTRO='This ADR continues an existing PR through **no-mistakes**: `done:` means that PR is updated with checks green.'
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_LOCAL='A clean local ADR commit or push is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR https://... checks green` using the existing PR full URL.'
      DOD_NO_MISTAKES_COMPLETE="The ADR is ready for validation only when committed at detached HEAD and pushed to the existing branch \`$task_branch\`."
      DOD_NO_MISTAKES_HANDOFF="When the ADR is complete, committed, and pushed to the existing branch, append \`${FM_DOD_PAUSED_VERB}: ADR complete, committed, and pushed, ready to validate\` and stop there; that handoff is a defined stopping point and a declared wait, and firstmate will then instruct you to run /no-mistakes to validate and update the existing ADR PR."
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_DONE='After /no-mistakes reports CI green for the existing ADR PR (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR https://... checks green` using that PR full URL and stop. You are finished.'
      ;;
  esac
}

fm_dod_render() {  # <mode>
  local mode=$1
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
$DOD_DIRECT
$DOD_DIRECT_INTRO
$DOD_DIRECT_COMPLETE
$DOD_DIRECT_HANDOFF
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
$DOD_LOCAL
$DOD_LOCAL_INTRO
$DOD_LOCAL_COMPLETE
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
$DOD_LOCAL_HANDOFF
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
$DOD_NO_MISTAKES
$DOD_NO_MISTAKES_INTRO
$DOD_NO_MISTAKES_LOCAL
$DOD_NO_MISTAKES_COMPLETE
$DOD_NO_MISTAKES_HANDOFF

$DOD_NO_MISTAKES_DRIVE
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
$DOD_NO_MISTAKES_ACTIVE
$DOD_NO_MISTAKES_PARK

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
$DOD_NO_MISTAKES_ASK
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

$DOD_NO_MISTAKES_DONE
EOF
      ;;
    *)
      echo "error: fm_dod_render: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}

fm_dod_block() {  # <mode> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR|local-only|no-mistakes) ;;
    *) echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2; return 1 ;;
  esac
  fm_dod_fragments ship "fm/$id" "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}"
  fm_dod_render "$mode"
}
