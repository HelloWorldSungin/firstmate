#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates. Continuing an existing branch is not one of
# those hand-edits: pass --continue-branch so the generated Setup and the
# task-branch marker agree, rather than contradicting git checkout -b from the
# Task section.
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--continue-branch <name>] [--query <text>] [--issue <number>] [--work-item <forge>:<url>]... [--pr-target <forge>:<host>/<path>] [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --design --mode <no-mistakes|direct-PR|local-only> [--continue-branch <name>] [--query <text>] [--issue <number>] [--work-item <forge>:<url>]... [--pr-target <forge>:<host>/<path>] [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--query <text>] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --query <text> is the task's own words for the scaffold-time brain read below;
#   without it the query is the task id with its dashes read as spaces.
#   --work-item records a resolved work item that lives in the MANAGED PROJECT's
#   tracker, which is usually not this repository. It is repeatable, so a task
#   may carry several references or none, and it takes only a fully resolved
#   "<forge>:<url>" argument. Resolving a loose reference (a bare number, an
#   owner/repo#N, a project's declared tracker) is intake's job, exactly like
#   delivery mode: firstmate runs bin/fm-issue-ref.sh --format brief and passes
#   the result here. This script reads data/projects.md only to tell whether a
#   project's clone is the home root (bin/fm-brief-repo-lib.sh) and never
#   guesses a forge, so a brief cannot silently point at the wrong tracker.
#   --issue is the older same-repository GitHub form: a bare number that means
#   "this issue lives in whichever repository the PR lands in". It still works
#   for a task shipping to its own GitHub tracker, but it cannot express a
#   mirrored project, so prefer --work-item. The two are mutually exclusive.
#   The generated --issue section requires a substantive issue comment and a
#   `Closes` line in the PR body. The --work-item section decides that per item
#   against --pr-target: an item whose tracker IS the repository the PR opens
#   against carries the same substantive-comment and `Closes` contract, because
#   a forge can only auto-close its own issues from its own PR body, and every
#   other item stays link-only for that same reason. Link-only is not a gap in
#   the bookkeeping: firstmate closes a cross-forge item itself on its merge
#   path (docs/configuration.md "Project issue trackers").
#   --pr-target is therefore REQUIRED with --work-item and names the tracker
#   identity of the repository this task's PR opens against, in the same
#   <forge>:<host>/<path> spelling data/projects.md uses. It is required rather
#   than optional because an absent PR target would silently drop the write-back
#   contract from every brief - the exact regression this flag exists to end -
#   and firstmate already resolves the project's forge identity at intake.
#   Either way fm-spawn.sh copies the explicit markers into task metadata, where
#   bin/fm-issue-comment.sh reads the recorded PR target to decide whether it may
#   write firstmate's own living status comment to that tracker.
#   --design writes the interactive design contract: the worker reads the
#   installed mattpocock grilling and domain-modeling skills, asks one
#   evidence-first question at a time through firstmate, and produces a tracked
#   ADR through the selected delivery mode. The plugin is read in place and is
#   never installed, updated, copied, vendored, pinned, or modified here.
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
#   When the resolved project checkout shares FM_ROOT's git object database,
#   ship, design, and scout scaffolds also emit firstmate-repo crew role guidance so a
#   worker does not inherit firstmate's captain-facing AGENTS.md persona; ship
#   and design briefs additionally require the firstmate-coding-guidelines skill, which a
#   report-only scout has no tracked material to need. Firstmate's own checkout
#   is the home root rather than a clone under projects/. Home-root resolution
#   is structural and registry-prose-independent; bin/fm-brief-repo-lib.sh owns
#   the candidate mechanics and final object-database verdict.
# For ship and design tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads a mode from it:
# Without --continue-branch, ship modes deliver an authorized implementation:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# Design modes deliver only the ADR:
#   no-mistakes  ADR commit -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    ADR commit -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   ADR on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# The generated ship or design brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship or design task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# It also records the exact tracked-output branch in a firstmate-task-branch marker.
# bin/fm-spawn.sh copies that marker into branch= task metadata, making the task's
# own branch durable before the worker creates or continues it instead of
# reconstructing it later from the task id or from whichever branch the pooled
# worktree currently hosts.
# --continue-branch <name> is how a ship or design task continues an existing
# branch instead of git checkout -b fm/<task-id>. It writes that name into the
# marker so spawn records the branch the worker will actually use, and replaces
# the Setup branch action plus mode-specific branch and existing-PR wording.
# Omit it for the ordinary new-branch strategy; the generated Setup text is then
# unchanged. Refused on scout and secondmate scaffolds. It requires a resolvable
# project checkout and a valid non-default branch name other than fm/<task-id>,
# which is the ordinary strategy.
# This header is the owner of the checkout-versus-push rule: a branch held by another worktree blocks checkout, not push.
# The generated continue-branch first action therefore keeps the worker detached
# and updates the existing branch with git push origin HEAD:<name> (or a local
# git update-ref under local-only). No stack, merge, or cherry-pick is required.
# Ship and design briefs begin with a worktree-isolation assertion before the branch step.
# --mode is refused on scout and secondmate scaffolds: a scout's deliverable is a
# report rather than a merge, and a charter is not a delivery contract.
# There is no --yolo flag here. The worker never owns merge decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act. Ship and design briefs teach both with worked examples,
# and ship briefs use blocked for the no-mistakes validation-trigger handoff.
# Ship, design, and scout briefs also require a readable current state after "resolved:".
# They identify firstmate as the worker's instructor and require firstmate attribution
# in resolved status, reports, PR bodies, and commits unless the decision text explicitly
# says the captain was consulted; secondmate charters apply the same rule to resolved status.
# Ship and design briefs pair the pause verb with "working:" around backgrounded pipeline calls.
# Those same briefs warn that a `pgrep -f` or `pkill -f` wait whose pattern appears in the wait's own command line matches itself and never exits, so wait or kill by PID.
# For a no-mistakes ship, "done:" means the PR is open with checks green, so the
# implementation handoff before validation uses blocked:, not the pause verb.
# Design tasks instead use ADR-specific no-mistakes handoff wording in the generated brief.
# Every scaffold also carries the steering-inbox receive-and-ack section:
# process state/<id>.inbox/*.msg in order and acknowledge each by moving it to
# handled/ (record, doorbell, and ladder owned by bin/fm-task-inbox-lib.sh).
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Design tasks omit it because their sole tracked project deliverable is the ADR.
# Brain section (docs/adr/0001-brain-read-mount.md D1 and D4): every scaffold in a
# home whose brain has a local index carries the retrieval instruction, and a
# ship, design, or scout scaffold additionally runs ONE scope-local
# bin/fm-recall.sh search with the task's words (--query, else the task id) at
# --limit 5 --excerpt 400 --timeout 10, never think. When the installed wrapper
# is observed to emit the framed answer and per-result provenance fields, the
# rows become a bounded, provenance-labeled citations block (about 3,300 bytes,
# ~1,100 estimated tokens) after the instruction; when the search never starts,
# fails, times out, returns no rows, or emits an unframed document, the brief
# carries the instruction alone and the scaffold still succeeds. The same search
# prints at most one advisory "nearest prior work" stdout line for firstmate.
# After skipping rows that are definitely not tasks, it names the earliest
# classifiable task whose report is safe and readable, or says no local report
# exists; a task-shaped unclassifiable row leaves the advisory silent rather
# than guessing. The line claims
# proximity, never duplication, is independent of whether the embed mounted,
# and never enters the brief. A home with no local index runs no search and
# omits the section. The secondmate charter carries the instruction alone.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-task-branch-lib.sh
. "$SCRIPT_DIR/fm-task-branch-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-gbrain-lib.sh
. "$SCRIPT_DIR/fm-gbrain-lib.sh"
# shellcheck source=bin/fm-brief-repo-lib.sh
. "$SCRIPT_DIR/fm-brief-repo-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
MODE=
MODE_SET=0
ISSUE=
ISSUE_SET=0
WORK_ITEMS=()
PR_TARGET=
PR_TARGET_SET=0
CONTINUE_BRANCH=
CONTINUE_BRANCH_SET=0
QUERY=
QUERY_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      issue) ISSUE=$a; ISSUE_SET=1 ;;
      work-item) WORK_ITEMS+=("$a") ;;
      pr-target) PR_TARGET=$a; PR_TARGET_SET=1 ;;
      continue-branch) CONTINUE_BRANCH=$a; CONTINUE_BRANCH_SET=1 ;;
      query) QUERY=$a; QUERY_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --design) KIND=design ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --issue) want_value=issue ;;
    --issue=*) ISSUE=${a#--issue=}; ISSUE_SET=1 ;;
    --work-item) want_value=work-item ;;
    --work-item=*) WORK_ITEMS+=("${a#--work-item=}") ;;
    --pr-target) want_value=pr-target ;;
    --pr-target=*) PR_TARGET=${a#--pr-target=}; PR_TARGET_SET=1 ;;
    --continue-branch) want_value=continue-branch ;;
    --continue-branch=*) CONTINUE_BRANCH=${a#--continue-branch=}; CONTINUE_BRANCH_SET=1 ;;
    --query) want_value=query ;;
    --query=*) QUERY=${a#--query=}; QUERY_SET=1 ;;
    # yolo never reaches the worker: it is firstmate's merge authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's merge posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

tracked_output_kind() {
  [ "$KIND" = ship ] || [ "$KIND" = design ]
}

if [ "$ISSUE_SET" -eq 1 ]; then
  case "$ISSUE" in
    ''|*[!0-9]*) echo "error: --issue requires a positive GitHub issue number" >&2; exit 1 ;;
  esac
  [ "$ISSUE" -gt 0 ] || { echo "error: --issue requires a positive GitHub issue number" >&2; exit 1; }
  tracked_output_kind || { echo "error: --issue applies only to ship or design briefs" >&2; exit 1; }
fi

# A resolved work item is validated here but never resolved here: only the
# fully qualified "<forge>:<url>" form is accepted, so this script needs no
# registry, no network, and no forge guess. Anything looser is intake's job.
if [ "${#WORK_ITEMS[@]}" -gt 0 ]; then
  tracked_output_kind || { echo "error: --work-item applies only to ship or design briefs" >&2; exit 1; }
  [ "$ISSUE_SET" -eq 0 ] || {
    echo "error: --issue and --work-item are mutually exclusive; --work-item states the tracker explicitly, which is what --issue cannot do" >&2
    exit 1
  }
  for item in "${WORK_ITEMS[@]}"; do
    case "$item" in
      *:https://*) ;;
      *)
        echo "error: --work-item requires a resolved <forge>:<url> argument (got '$item'); resolve loose references at intake with bin/fm-issue-ref.sh --project <name> --format brief" >&2
        exit 1
        ;;
    esac
    if ! fm_issue_ref_resolve "$item" "" ""; then
      echo "error: --work-item $item: $FM_ISSUE_ERROR" >&2
      exit 1
    fi
  done
  # Required, not optional: without the PR target this scaffold cannot tell an
  # item it may write back to from one it may not, and its only safe guess is
  # link-only - which is how the write-back contract silently disappeared from
  # every --work-item brief in the first place.
  [ "$PR_TARGET_SET" -eq 1 ] || {
    echo "error: --work-item requires --pr-target <forge>:<host>/<path> naming the repository this task's PR opens against; resolve it at intake from the project, the same way the work item itself is resolved" >&2
    exit 1
  }
  if ! fm_issue_tracker_parse "$PR_TARGET" || [ -z "$FM_ISSUE_TRACKER_FORGE" ]; then
    echo "error: --pr-target must be <forge>:<host>/<path> (got '$PR_TARGET')" >&2
    exit 1
  fi
  PR_TARGET_FORGE=$FM_ISSUE_TRACKER_FORGE
  PR_TARGET_HOST=$FM_ISSUE_TRACKER_HOST
  PR_TARGET_PATH=$FM_ISSUE_TRACKER_PATH
elif [ "$PR_TARGET_SET" -eq 1 ]; then
  echo "error: --pr-target describes where --work-item references may be written back and is meaningless without one" >&2
  exit 1
fi

# Tracked-output delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if tracked_output_kind; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship and design briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship or design briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi

# Issue traceability rides the PR, so it is meaningless without one.
if [ "$ISSUE_SET" -eq 1 ] && [ "$MODE" = local-only ]; then
  echo "error: --issue requires a PR-based delivery mode" >&2
  exit 1
fi
if [ "${#WORK_ITEMS[@]}" -gt 0 ] && [ "$MODE" = local-only ]; then
  echo "error: --work-item requires a PR-based delivery mode" >&2
  exit 1
fi

ID=${POS[0]}
REPO=${POS[1]:-}


if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship, design, or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

# The scaffold-time brain read queries with the task's own words. The task id
# is a slugged title, so it is the default; --query carries richer words when
# firstmate has them. A charter is not a commissioned task, so it takes none.
if [ "$QUERY_SET" -eq 1 ]; then
  [ "$KIND" != secondmate ] || { echo "error: --query applies only to ship, design, or scout briefs; a charter is not a commissioned task" >&2; exit 1; }
  case "$QUERY" in
    *[![:space:]]*) ;;
    *) echo "error: --query requires the task's words" >&2; exit 1 ;;
  esac
  BRAIN_QUERY=$QUERY
else
  BRAIN_QUERY=$(printf "%s" "$ID" | tr "_-" "  ")
fi

TASK_BRANCH="fm/$ID"
if [ "$CONTINUE_BRANCH_SET" -eq 1 ]; then
  tracked_output_kind || {
    echo "error: --continue-branch applies only to ship or design briefs" >&2
    exit 1
  }
  [ -n "$CONTINUE_BRANCH" ] || {
    echo "error: --continue-branch requires a git branch name" >&2
    exit 1
  }
  fm_task_branch_validate "$CONTINUE_BRANCH" || {
    echo "error: --continue-branch $FM_TASK_BRANCH_ERROR (got '$CONTINUE_BRANCH')" >&2
    exit 1
  }
  [ "$CONTINUE_BRANCH" != "fm/$ID" ] || {
    echo "error: --continue-branch fm/$ID is the ordinary new-branch strategy; omit the flag so the generated Setup keeps git checkout -b" >&2
    exit 1
  }
  PROJECT_DIR=$(fm_brief_resolve_project_dir "$REPO") || {
    echo "error: --continue-branch requires a resolvable project checkout so its default branch can be protected (got '$REPO')" >&2
    exit 1
  }
  DEFAULT_BRANCH=$(fm_default_branch "$PROJECT_DIR") || {
    echo "error: cannot determine the default branch for $PROJECT_DIR; expected origin/HEAD, main, or master" >&2
    exit 1
  }
  [ "$CONTINUE_BRANCH" != "$DEFAULT_BRANCH" ] || {
    echo "error: --continue-branch cannot name the repository default branch '$DEFAULT_BRANCH'" >&2
    exit 1
  }
  TASK_BRANCH=$CONTINUE_BRANCH
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
if [ "$KIND" = design ]; then
  "$FM_ROOT/bin/fm-design-skills.sh" check >/dev/null || {
    echo "error: --design requires the captain-installed mattpocock grilling and domain-modeling skills; do not install or copy them from a worker" >&2
    exit 1
  }
fi
mkdir -p "$DATA/$ID"

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
INBOX_DIR=$(shell_quote "$STATE/$ID.inbox")

# The receive-and-ack half of the steering-inbox contract, included in every
# scaffold kind. The record format, doorbell line, and re-ring ladder are
# owned by bin/fm-task-inbox-lib.sh; the doorbell itself is self-describing,
# so this section is reinforcement for the natural-checkpoint habit, not the
# only carrier of the instruction.
IFS= read -r -d '' INBOX_SECTION <<EOF || true
# Firstmate instruction inbox
Firstmate steers you through durable message files in $INBOX_DIR.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list $INBOX_DIR/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: \`mv $INBOX_DIR/NNN.msg $INBOX_DIR/handled/\`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.
EOF
INBOX_SECTION=${INBOX_SECTION%$'\n'}

# Brain retrieval is on demand and only worth mentioning to a worker whose home
# actually has an index to read, so the instruction appears when this home has
# built one and is silent otherwise rather than pointing every brief at a tool
# that would answer "no brain". bin/fm-recall.sh owns the retrieval contract.
#
# A ship, design, or scout scaffold also reads that index once, here, so the
# knowledge the fleet captures at teardown reaches a worker at the one moment it
# is commissioned (docs/adr/0001-brain-read-mount.md, D1 and D4). The mechanics
# below are this script's own: one scope-local search with the task's words,
# the pinned shape, the embed gate, the byte cap, and the stdout line. The
# secondmate charter keeps the instruction alone, because a charter is not a
# commissioned task with a query.
BRAIN_INSTRUCTION="This home keeps a searchable record of the fleet's prior work: run \`$FM_ROOT/bin/fm-recall.sh search <query>\` before re-deriving something already known, and cite anything you use by the \`<source>:<slug>\` label it prints.
Results are nearest indexed pages, not answers: a miss is absence of a match, never evidence that the queried thing is absent, a listed page may be unrelated or stale, and when a live source disagrees with a page the live source wins.
Retrieval stays on this host, but \`fm-recall.sh think\` sends your question and the excerpts it selects to a hosted provider, so reach for it only when local results are not enough and never for anything that must not leave this host."

# The search shape is pinned rather than inherited from the wrapper's defaults:
# five rows of 400 characters is the measured ~1,100-estimated-token embed, and
# 10 seconds is the ADR-pinned commissioning ceiling; slower or cold reads
# degrade to the instruction-only section instead of charging a dispatch the
# wrapper's full minute. The same --timeout also sizes the wrapper's
# provenance pass, so rows it does not reach arrive labeled unknown, which the
# gate below accepts: it tests that the provenance FIELDS are present, never
# that they hold a particular value.
BRAIN_SCAFFOLD_LIMIT=5
BRAIN_SCAFFOLD_EXCERPT=400
BRAIN_SCAFFOLD_TIMEOUT=10
# ceil(3300 / 3) = 1,100 estimated tokens, the embed bound the ADR names.
BRAIN_SCAFFOLD_EMBED_MAX_BYTES=3300
BRAIN_SCAFFOLD_QUERY_DISPLAY_CHARS=200

# One read, two outputs, two gates. The worker-facing embed becomes trusted
# context, so it mounts only when the installed wrapper is OBSERVED to emit the
# framed answer and per-result provenance fields; the firstmate-facing line is
# independent of that embed gate, but prints only after task identities remain
# classifiable through the selected ranked candidate.
# Every other outcome - never started, failed, timed out, empty, unframed -
# leaves BRAIN_EMBED empty so the brief carries the instruction alone, and none
# of them can stop the scaffold. The wrapper's exit codes keep never-started
# (5) apart from asked-and-unanswered (3); the diagnostic names which.
brain_scaffold_read() {  # -> BRAIN_EMBED, BRAIN_NEAREST; both may stay empty
  local doc rc=0 detail citation="" title="" id="" state="" record="" report="" rows frame_bytes rendered cap_state
  local candidate_citation candidate_title candidate_kind candidate_id candidate_state candidate_classifiable
  local task_rows=0 identities_classifiable=1
  BRAIN_EMBED=""
  BRAIN_NEAREST=""
  if ! command -v jq >/dev/null 2>&1; then
    echo "brain: the search never started: jq is required; the brief carries the retrieval instruction only" >&2
    return 0
  fi
  doc=$("$FM_ROOT/bin/fm-recall.sh" search --json --home "$FM_HOME" --scope local \
    --limit "$BRAIN_SCAFFOLD_LIMIT" --excerpt "$BRAIN_SCAFFOLD_EXCERPT" \
    --timeout "$BRAIN_SCAFFOLD_TIMEOUT" -- "$BRAIN_QUERY" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    detail=$(printf '%s' "$doc" | jq -r '[.sources[]? | select(.state != "ok") | .detail // .state] | join("; ")' 2>/dev/null) || detail=""
    case "$rc" in
      5) detail="the search never started${detail:+: $detail}" ;;
      3) detail="the brain was asked and did not answer${detail:+: $detail}" ;;
      *) detail="fm-recall.sh exited $rc${detail:+: $detail}" ;;
    esac
    echo "brain: $detail; the brief carries the retrieval instruction only" >&2
    return 0
  fi
  printf '%s' "$doc" | jq -e '.schema == "fm-recall.v1" and (.results | type) == "array"' >/dev/null 2>&1 || {
    echo "brain: the search returned something other than an fm-recall.v1 document; the brief carries the retrieval instruction only" >&2
    return 0
  }
  # D4: skip rows that are definitely not tasks, then name the first ranked
  # classifiable task whose completed report this home can read. A task-shaped
  # row with unclassifiable identity stops the claim rather than letting a lower
  # row masquerade as nearest. Ungated, advisory, and never in the brief. Reports
  # are looked up under the brain's own home, the same place the wrapper reads
  # provenance from, rather than under a relocated brief directory.
  while IFS= read -r -d '' candidate_citation \
      && IFS= read -r -d '' candidate_title \
      && IFS= read -r -d '' candidate_kind \
      && IFS= read -r -d '' candidate_id \
      && IFS= read -r -d '' candidate_state \
      && IFS= read -r -d '' candidate_classifiable; do
    if [ "$candidate_classifiable" != true ]; then
      identities_classifiable=0
      break
    fi
    [ "$candidate_kind" = task ] || continue
    task_rows=$((task_rows + 1))
    record="$FM_HOME/data/$candidate_id"
    report="$record/report.md"
    [ ! -L "$record" ] && [ ! -L "$report" ] && [ -f "$report" ] && [ -r "$report" ] || continue
    citation=$candidate_citation
    title=$candidate_title
    id=$candidate_id
    state=$candidate_state
    break
  done < <(printf '%s' "$doc" | jq -j '
    def source_id_valid:
      type == "string"
      and test("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$");
    def document_id_valid:
      type == "string"
      and length <= 200
      and test("^v1\\.[A-Za-z0-9._-]+$");
    def task_slug:
      if ((.slug | type) == "string"
          and (.slug | test("^firstmate/[^/]+/task/[^/]+$"))) then
        .slug | capture("^firstmate/(?<tag>[^/]+)/task/(?<id>[^/]+)$")
      else null
      end;
    def identity:
      task_slug as $slug
      | if $slug == null then
          {kind: "", id: "", classifiable: true}
        elif ((($slug.id | source_id_valid)
              and ("v1." + $slug.tag + ".task." + $slug.id | document_id_valid)) | not) then
          {kind: "", id: "", classifiable: false}
        elif has("source_kind") or has("source_id") then
          if (.source_kind == "task"
              and (.source_id | source_id_valid)
              and .source_id == $slug.id)
          then {kind: "task", id: .source_id, classifiable: true}
          else {kind: "", id: "", classifiable: false}
          end
        else {kind: "task", id: $slug.id, classifiable: true}
      end;
    def displayed($cap):
      tostring
      | explode
      | map(if (. < 32 or (. >= 127 and . <= 159) or . == 8232 or . == 8233) then 32 else . end)
      | implode
      | gsub("\\s+"; " ")
      | sub("^ "; "")
      | sub(" $"; "")
      | .[0:$cap];
    .results[]
    | identity as $identity
    | ((.citation // .slug // "") | displayed(256)), "\u0000",
      ((.title // "(untitled)") | displayed(200)), "\u0000",
      $identity.kind, "\u0000",
      $identity.id, "\u0000",
      ((.source_state // "unknown") | displayed(32)), "\u0000",
      ($identity.classifiable | tostring), "\u0000"' 2>/dev/null)
  if [ -n "$id" ]; then
    BRAIN_NEAREST="nearest prior work (proximity, not duplication): \"$title\"${citation:+ $citation}; live source $state; report $report"
  elif [ "$task_rows" -gt 0 ] && [ "$identities_classifiable" -eq 1 ]; then
    BRAIN_NEAREST="nearest prior work (proximity, not duplication): no local report"
  fi
  # D1: the embed, gated on the answer contract being observed in this document.
  printf '%s' "$doc" | jq -e '
    (.answer | type) == "object" and .answer.kind == "nearest"
    and (.results | length) > 0
    and all(.results[]; has("captured_at") and has("source_state"))' >/dev/null 2>&1 || return 0
  frame_bytes=$(printf '%s' "$BRAIN_INSTRUCTION" | wc -c)
  rendered=$(printf '%s' "$doc" | jq -c \
    --argjson cap "$((BRAIN_SCAFFOLD_EMBED_MAX_BYTES - frame_bytes))" \
    --argjson query_cap "$BRAIN_SCAFFOLD_QUERY_DISPLAY_CHARS" --arg query "$BRAIN_QUERY" '
    def row:
      "- `\(.citation // .slug)` - \((.title // "(untitled)") | .[0:200])\n"
      + "  captured: \(.captured_at // "unknown"); live source: \(.source_state // "unknown")"
      + (if .source_state == "drifted" then " (the live source wins)" else "" end)
      + (if .stale == true then "; stale" else "" end)
      + (if .source_updated_at then "; live updated: \(.source_updated_at)" else "" end)
      + "\n  > \((.excerpt // "") | gsub("\\s+"; " "))\n";
    def displayed_query:
      ($query | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")) as $normalized
      | if ($normalized | length) > $query_cap
        then $normalized[0:($query_cap - 3)] + "..."
        else $normalized
        end;
    def frame:
      "One such search already ran for this task at scaffold time (query: \(displayed_query)); its nearest pages, with capture and live-source provenance, follow. Read them as candidates to compare, never as proof the work was done.\n";
    def tail:
      if .answer.no_confident_match == true
      then "The brain'"'"'s own confidence floor cleared none of these, so treat them as loosely related at best.\n"
      else "" end;
    frame as $frame
    | tail as $tail
    # The parentheses are a real fix, not grouping for readability. On jq 1.6
    # and 1.7.1, `a + b as $x | body` binds `as` to `b` alone, so `a` is added
    # to the string the body produces and the whole render errors, silently
    # dropping the citations block; jq 1.8.1 binds the complete sum either
    # way. Verified 2026-09-02 by running the official 1.6, 1.7.1, and 1.8.1
    # binaries: unparenthesized errors on 1.6 and 1.7.1, parenthesized renders
    # on all three. The version that makes the parentheses load-bearing in CI
    # is 1.7.1, which the ubuntu-latest runner image ships; no other version
    # was run. No apostrophe may appear in this comment: it sits inside
    # the single-quoted jq program.
    | (($frame | utf8bytelength) + ($tail | utf8bytelength)) as $fixed
    | [ .results[] ]
    | reduce .[] as $r ([]; if any(.[]; .citation == $r.citation) then . else . + [$r] end)
    | map(row) as $lines
    | reduce $lines[] as $line ({text: "", bytes: $fixed, mounted: 0, truncated: false};
        if .truncated then .
        elif (.bytes + ($line | utf8bytelength)) > $cap then .truncated = true
        else {
          text: (.text + $line),
          bytes: (.bytes + ($line | utf8bytelength)),
          mounted: (.mounted + 1),
          truncated: false
        }
        end)
    | {
        text: (if .mounted == 0 then "" else $frame + .text + $tail end),
        cap_state: (if .truncated then (if .mounted == 0 then "dropped" else "truncated" end) else "complete" end)
      }' 2>/dev/null) || rendered=""
  if [ -z "$rendered" ]; then
    echo "brain: the citations block could not be rendered; the brief carries the retrieval instruction only" >&2
    return 0
  fi
  rows=$(printf '%s' "$rendered" | jq -r '.text') || rows=""
  cap_state=$(printf '%s' "$rendered" | jq -r '.cap_state') || cap_state=render_failed
  case "$cap_state" in
    dropped)
      echo "brain: the citations block was dropped because no citation fit the ${BRAIN_SCAFFOLD_EMBED_MAX_BYTES}-byte cap; the brief carries the retrieval instruction only" >&2
      ;;
    truncated)
      echo "brain: the citations block was truncated by the ${BRAIN_SCAFFOLD_EMBED_MAX_BYTES}-byte cap; trailing citations were omitted" >&2
      ;;
  esac
  BRAIN_EMBED=$rows
}

BRAIN_SECTION=""
if fm_gbrain_resolve_paths "$FM_HOME" && [ -d "$FM_GBRAIN_PGLITE" ]; then
  BRAIN_SECTION="# Brain
$BRAIN_INSTRUCTION

"
  if [ "$KIND" != secondmate ]; then
    brain_scaffold_read
    [ -z "$BRAIN_NEAREST" ] || printf '%s\n' "$BRAIN_NEAREST"
    if [ -n "$BRAIN_EMBED" ]; then
      BRAIN_SECTION="# Brain
$BRAIN_INSTRUCTION
$BRAIN_EMBED

"
    fi
  fi
fi

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`captain-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.
A request arriving through the instruction inbox below follows the same marker and reply rules.

$INBOX_SECTION

${BRAIN_SECTION}# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, work ready for review, or work you landed.
Work you landed includes a merge you performed yourself under standing merge authority and one the captain merged on the forge: under that authority nothing is ever \"ready for review\", so a landed merge that goes unreported reaches the captain as silence.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
\`resolved\` separately closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it: a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main firstmate's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main firstmate, append \`resolved: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one) as your domain resumes.
Name the main firstmate in \`resolved:\` lines unless the decision text explicitly states the captain was consulted.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

# When a crewmate's disposable worktree is the firstmate repository itself, the
# checkout's AGENTS.md installs firstmate's captain-facing persona. Emit an
# explicit counter-instruction in the brief rather than neutralizing those
# files, which would also hide coding guidelines and safety boundaries the
# worker legitimately needs. Detection compares git-common-dir against FM_ROOT
# instead of trusting the caller-supplied REPO name (bin/fm-brief-repo-lib.sh).
#
# The role fact holds for every firstmate-repo task, so both scaffolds carry it:
# a scout inherits the persona just as readily and simply has no PR to leak it
# into. The coding-guidelines directive is tracked-output-only, because telling a scout it
# is changing shared tracked material would put a false statement in its brief -
# a scout's only deliverable is a report (see the scout Rules below).
FIRSTMATE_REPO_CREW_SECTION=
if fm_brief_task_repo_is_firstmate "$REPO"; then
  IFS= read -r -d '' FIRSTMATE_REPO_ROLE_FACT <<'EOF' || true
**You report to FIRSTMATE, not the captain.** You are working in a checkout of firstmate itself, so this worktree carries firstmate's own `AGENTS.md` and its `CLAUDE.md` symlink. Those instructions describe **firstmate's** role, including a mandatory captain address. They are not your instructions; follow the reporting line and attribution rules in the rules below.

If you notice yourself reaching for the word "captain", treat that as role confusion rather than your reporting line.
EOF
  if [ "$KIND" = scout ]; then
    FIRSTMATE_REPO_CREW_SECTION="# Before you start - one firstmate-repo fact

$FIRSTMATE_REPO_ROLE_FACT"
  else
    IFS= read -r -d '' FIRSTMATE_REPO_GUIDELINES <<'EOF' || true
**Load the `firstmate-coding-guidelines` skill first.** This task changes firstmate's shared tracked material, and that skill owns the repo's style and knowledge-placement rules: one sentence per line, plain dash never an em dash, shellcheck-clean scripts, colocated tests, the one-owner rule for contracts, and no agent name as a commit co-author.
EOF
    FIRSTMATE_REPO_CREW_SECTION="# Before you edit anything - two firstmate-repo facts

$FIRSTMATE_REPO_GUIDELINES
$FIRSTMATE_REPO_ROLE_FACT"
  fi
  # Each part carries its own trailing newline, so the section is trimmed to end
  # without one and the separator appended below supplies exactly the single
  # blank line every sibling section leaves before the next heading.
  FIRSTMATE_REPO_CREW_SECTION=${FIRSTMATE_REPO_CREW_SECTION%$'\n'}
  FIRSTMATE_REPO_CREW_SECTION="$FIRSTMATE_REPO_CREW_SECTION

"
fi

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

ISSUE_SECTION=
if [ "$ISSUE_SET" -eq 1 ]; then
  IFS= read -r -d '' ISSUE_SECTION <<EOF || true
<!-- firstmate-task-issue=$ISSUE -->
# GitHub issue traceability
Before reporting the PR ready, comment on GitHub issue #$ISSUE with a substantive summary of what you found and what you actually changed.
A bare "done" comment does not satisfy this contract: someone reading the issue later must be able to understand the outcome without opening the PR.
Put \`Closes #$ISSUE\` in the PR body so merging the PR closes the issue atomically.
Amend the existing PR body rather than replacing it: the pipeline that opened the PR owns sections of that body, and a wholesale rewrite drops the signature its required checks look for.
EOF
  ISSUE_SECTION=${ISSUE_SECTION%$'\n'}
  ISSUE_SECTION="$ISSUE_SECTION

"
fi

if [ "${#WORK_ITEMS[@]}" -gt 0 ]; then
  # Each item is classified against the PR target: same repository means the
  # worker owes it a substantive delivery summary and a Closes line, because a
  # forge can only auto-close its own issues from its own PR body. Every other
  # item is linked and left to firstmate's own merge path, which closes it on
  # its own host (docs/configuration.md "Project issue trackers").
  WORK_ITEM_MARKERS=
  WORK_ITEM_LINES=
  SAME_REPO_ITEMS=0
  for item in "${WORK_ITEMS[@]}"; do
    fm_issue_ref_resolve "$item" "" "" || { echo "error: --work-item $item: $FM_ISSUE_ERROR" >&2; exit 1; }
    WORK_ITEM_MARKERS="$WORK_ITEM_MARKERS<!-- firstmate-work-item=$FM_ISSUE_FORGE:$FM_ISSUE_URL -->
"
    if [ "$FM_ISSUE_FORGE" = "$PR_TARGET_FORGE" ] && [ "$FM_ISSUE_HOST" = "$PR_TARGET_HOST" ] \
      && [ "$FM_ISSUE_PATH" = "$PR_TARGET_PATH" ]; then
      SAME_REPO_ITEMS=$((SAME_REPO_ITEMS + 1))
      WORK_ITEM_LINES="$WORK_ITEM_LINES- $FM_ISSUE_URL lives in the repository this PR opens against: before reporting the PR ready, comment on it with a substantive summary of what you found and what you actually changed, and put \`Closes #$FM_ISSUE_NUMBER\` in the PR body.
"
    else
      WORK_ITEM_LINES="$WORK_ITEM_LINES- $FM_ISSUE_URL lives on another tracker: reference it in the PR body and leave its bookkeeping to firstmate, which closes it through its own merge path.
"
    fi
  done
  SUMMARY_BAR=
  if [ "$SAME_REPO_ITEMS" -gt 0 ]; then
    SUMMARY_BAR='A bare "done" comment does not satisfy this contract: someone reading the issue later must be able to understand the outcome without opening the PR.
Firstmate keeps its own running status comment on the same issue, so write yours as the delivery summary rather than a progress note.
'
  fi
  # Both parts carry their own line terminators, so the block is trimmed to end
  # without one: the heredoc below then supplies exactly one, as the --issue form
  # already does, and the separator appended after it is what spaces the section.
  # Without the trim the section is the document's only double-blank boundary.
  WORK_ITEM_BLOCK="${WORK_ITEM_LINES}${SUMMARY_BAR}"
  WORK_ITEM_BLOCK=${WORK_ITEM_BLOCK%$'\n'}
  IFS= read -r -d '' ISSUE_SECTION <<EOF || true
${WORK_ITEM_MARKERS}<!-- firstmate-pr-target=$PR_TARGET_FORGE:$PR_TARGET_HOST/$PR_TARGET_PATH -->
# Work item traceability
This task is linked to the work items below.
They live in the project's own tracker, which is not necessarily the repository your PR opens against, so use the full URLs rather than a bare number.
Reference each full URL in the PR body.
Amend the existing PR body rather than replacing it: the pipeline that opened the PR owns sections of that body, and a wholesale rewrite drops the signature its required checks look for.
${WORK_ITEM_BLOCK}
EOF
  ISSUE_SECTION=${ISSUE_SECTION%$'\n'}
  ISSUE_SECTION="$ISSUE_SECTION

"
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

${FIRSTMATE_REPO_CREW_SECTION}# Task
{TASK}

$ISSUE_SECTION$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is your only task-authored deliverable, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   You are instructed by firstmate; the captain is not in the loop.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
   Name firstmate in \`resolved:\` lines, reports, and commits unless the decision text explicitly states the captain was consulted.
   \`resolved:\` carries NO state, so it must never be your last line: append the next state line
   (normally \`working:\`) in the same breath. A trailing \`resolved:\` makes you read as no state at
   all - invisible to firstmate and indistinguishable from a dead worker, which is worse than stale.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

$INBOX_SECTION

${BRAIN_SECTION}# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
If your deliverable is a visual artifact the captain will review and iterate on, you may host the Lavish review loop yourself (poll, revise, re-serve, staying alive) instead of handing it back to firstmate.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Tracked-output task: shape Setup / Rule 1 / Definition of done by this task's explicit
# delivery mode, validated above. The generated DOD opens with the fixed
# "Delivery contract: mode=<mode>" line that bin/fm-spawn.sh checks against its own
# explicit --mode before launching.
DESIGN_SECTION=
DESIGN_DOD=
IFS= read -r -d '' DECISION_RULE <<'EOF' || true
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append `needs-decision: {summary of options}` and stop. Firstmate will apply the configured authority and reply with the decision.
   You are instructed by firstmate; the captain is not in the loop.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.
   Name firstmate in `resolved:` lines, PR bodies, and commits unless the decision text explicitly states the captain was consulted.
EOF
DECISION_RULE=${DECISION_RULE%$'\n'}
OUTPUT_KIND=ship
if [ "$KIND" = design ]; then
  OUTPUT_KIND=design
  IFS= read -r -d '' DESIGN_SECTION <<EOF || true
# Design profile
This is an interactive DESIGN task whose only tracked project deliverable is one architectural decision record.
Do not implement the resulting design or make unrelated project changes.
Do not create or modify any other tracked project file, including \`AGENTS.md\` or \`CLAUDE.md\`.

Read and follow \`$FM_ROOT/.agents/skills/design-profile/SKILL.md\` before beginning the interview.
At dispatch Firstmate prepends the exact \`grilling\` and \`domain_modeling\` paths from the resolver call whose plugin release it records for this task.
Read only those dispatch-pinned paths, never resolve the plugin again from this worker, and stop with the binding's blocker if either exact file is unavailable.
This direct file-binding contract is identical on Claude, Codex, and Pi and does not depend on harness-specific skill-command spelling.
Never install, update, copy, vendor, pin, or modify that plugin from this task.
Use those skills for modeling and interrogation only.
Do not create or update \`CONTEXT.md\`, even if a dependency instructs you to do so.
Record every resolved term only in the ADR so it remains the sole tracked project deliverable.

Investigate factual questions from repository evidence before asking for a decision.
Ask exactly one decision question at a time, with one stable key, the evidence, and your recommended answer.
Append \`needs-decision [key=<stable-slug>]: {one question} Recommendation: {answer and evidence}\`, then stop and wait.
Never batch questions, answer on behalf of firstmate, or proceed while the current key is unresolved.
When an answer arrives, append \`resolved [key=<same-stable-slug>]: {decision returned by firstmate}\` and \`working: continuing the design interview\` in the same breath, then capture the decision in the ADR.
State the converged decision back to firstmate before drafting the ADR.

Use an existing project ADR convention when one exists.
Otherwise use \`docs/adr/NNNN-<slug>.md\`, incrementing the highest existing number.
The ADR must stand alone with context, decision, rationale, relevant alternatives, and non-obvious consequences.
EOF
  DESIGN_SECTION=${DESIGN_SECTION%$'\n'}
  IFS= read -r -d '' DESIGN_DOD <<EOF || true
Before reporting the ADR ready, read and follow \`$FM_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for every unresolved decision surfaced by the interview or ADR.
Inspect the branch diff and confirm the ADR is the only worker-authored tracked project change.
The final status summary must name the ADR path and concisely state the decisions taken.
EOF
  DESIGN_DOD=${DESIGN_DOD%$'\n'}
  IFS= read -r -d '' DECISION_RULE <<'EOF' || true
6. Every design question follows the one-at-a-time Design profile contract above.
   Firstmate owns the answer or escalation; you are instructed by firstmate and the captain is not in the loop.
   Use the same stable key on the `needs-decision` event and the `resolved` event that closes it, and do not continue while that key is unanswered.
   Name firstmate in `resolved:` lines, PR bodies, and commits unless the decision text explicitly states the captain was consulted.
EOF
  DECISION_RULE=${DECISION_RULE%$'\n'}
fi

TRACKED_SECTIONS=$HERDR_SECTION
DOD_DIRECT='Delivery contract: mode=direct-PR'
DOD_LOCAL='Delivery contract: mode=local-only'
DOD_NO_MISTAKES='Delivery contract: mode=no-mistakes'
DOD_DIRECT_INTRO='This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.'
DOD_DIRECT_COMPLETE='The task is complete only when committed on your branch.'
# shellcheck disable=SC2016 # Backticks are literal generated Markdown.
DOD_DIRECT_HANDOFF='When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.'
DOD_LOCAL_INTRO='This task ships **local-only**: no remote, no PR, no pipeline.'
DOD_LOCAL_COMPLETE="The task is complete only when committed on your branch \`$TASK_BRANCH\`. Do NOT push, do NOT open a PR, do NOT merge."
DOD_LOCAL_HANDOFF="When it is implemented and committed, append \`done: ready in branch $TASK_BRANCH\` to the status file and stop."
# shellcheck disable=SC2016 # Backticks are literal generated Markdown.
DOD_NO_MISTAKES_INTRO='This project ships **no-mistakes**: `done:` means the PR is open with its checks green.'
# shellcheck disable=SC2016 # Backticks are literal generated Markdown.
DOD_NO_MISTAKES_LOCAL='A clean local commit is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR {url} checks green`.'
DOD_NO_MISTAKES_COMPLETE='The task is complete only when committed on your branch.'
DOD_NO_MISTAKES_HANDOFF="When you believe implementation is complete, append \`blocked: implemented and committed, ready to validate\` and stop there; that handoff is a defined stopping point because firstmate must trigger validation before you run /no-mistakes - use \`blocked:\`, not \`$PAUSED_VERB:\`, which would defer recheck for an hour under away mode."
DOD_NO_MISTAKES_DRIVE='You drive no-mistakes by responding to its gates, not by implementing fixes.'
DOD_NO_MISTAKES_ACTIVE='Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.'
# shellcheck disable=SC2016 # Backticks are literal generated Markdown.
DOD_NO_MISTAKES_ASK='  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.'
# shellcheck disable=SC2016 # Backticks are literal generated Markdown.
DOD_NO_MISTAKES_DONE='After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.'
PROJECT_MEMORY_SECTION=
if [ "$KIND" = ship ]; then
  IFS= read -r -d '' PROJECT_MEMORY_SECTION <<EOF || true
# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

EOF
fi
if [ -n "$DESIGN_SECTION" ]; then
  printf -v TRACKED_SECTIONS '%s\n\n%s' "$HERDR_SECTION" "$DESIGN_SECTION"
  printf -v DOD_DIRECT '%s\n%s' "$DOD_DIRECT" "$DESIGN_DOD"
  printf -v DOD_LOCAL '%s\n%s' "$DOD_LOCAL" "$DESIGN_DOD"
  printf -v DOD_NO_MISTAKES '%s\n%s' "$DOD_NO_MISTAKES" "$DESIGN_DOD"
  DOD_DIRECT_INTRO='This ADR ships **direct-PR**: you raise its PR yourself, without the no-mistakes pipeline.'
  DOD_DIRECT_COMPLETE='The ADR is ready only when committed on your branch.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_DIRECT_HANDOFF='When the ADR is complete and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.'
  DOD_LOCAL_INTRO='This ADR ships **local-only**: no remote, no PR, no pipeline.'
  DOD_LOCAL_COMPLETE="The ADR is ready only when committed on your branch \`$TASK_BRANCH\`. Do NOT push, do NOT open a PR, do NOT merge."
  DOD_LOCAL_HANDOFF="When the ADR is complete and committed, append \`done: ready in branch $TASK_BRANCH\` to the status file and stop."
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_INTRO='This ADR ships through **no-mistakes**: `done:` means the PR is open with its checks green.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_LOCAL='A clean local ADR commit is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR {url} checks green`.'
  DOD_NO_MISTAKES_COMPLETE='The ADR is ready for validation only when committed on your branch.'
  DOD_NO_MISTAKES_HANDOFF="When the ADR is complete and committed, append \`$PAUSED_VERB: ADR complete and committed, ready to validate\` and stop there; that handoff is a defined stopping point and a declared wait, and firstmate will then instruct you to run /no-mistakes to validate and ship the ADR PR."
  DOD_NO_MISTAKES_DRIVE='You drive no-mistakes by responding to its gates, not by applying fixes.'
  DOD_NO_MISTAKES_ACTIVE='Do not hand-edit, commit, or apply findings yourself while a run is active - the pipeline applies every fix.'
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  DOD_NO_MISTAKES_ASK='  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or apply the fix yourself.'
fi

if [ "$CONTINUE_BRANCH_SET" -eq 1 ]; then
  TASK_BRANCH_SHELL=$(shell_quote "$TASK_BRANCH")
  TASK_BRANCH_REF_SHELL=$(shell_quote "refs/heads/$TASK_BRANCH")
  TASK_BRANCH_PUSH_SHELL=$(shell_quote "HEAD:$TASK_BRANCH")
  case "$MODE:$KIND" in
    direct-PR:ship)
      DOD_DIRECT_INTRO='This task continues an existing PR through **direct-PR**, without the no-mistakes pipeline.'
      DOD_DIRECT_COMPLETE='The task is complete only when committed at detached HEAD.'
      DOD_DIRECT_HANDOFF="When it is implemented and committed, push with \`git push origin $TASK_BRANCH_PUSH_SHELL\`, use \`gh-axi\` to confirm the existing PR was updated, then append \`done: PR https://...\` with that PR's full URL to the status file and stop."
      ;;
    direct-PR:design)
      DOD_DIRECT_INTRO='This ADR continues an existing PR through **direct-PR**, without the no-mistakes pipeline.'
      DOD_DIRECT_COMPLETE='The ADR is ready only when committed at detached HEAD.'
      DOD_DIRECT_HANDOFF="When the ADR is complete and committed, push with \`git push origin $TASK_BRANCH_PUSH_SHELL\`, use \`gh-axi\` to confirm the existing PR was updated, then append \`done: PR https://...\` with that PR's full URL to the status file and stop."
      ;;
    local-only:ship)
      DOD_LOCAL_COMPLETE="The task is complete only when committed at detached HEAD and local branch \`$TASK_BRANCH\` points to that commit. Do NOT push, do NOT open a PR, do NOT merge."
      ;;
    local-only:design)
      DOD_LOCAL_COMPLETE="The ADR is ready only when committed at detached HEAD and local branch \`$TASK_BRANCH\` points to that commit. Do NOT push, do NOT open a PR, do NOT merge."
      ;;
    no-mistakes:ship)
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_INTRO='This task continues an existing PR through **no-mistakes**: `done:` means that PR is updated with checks green.'
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_LOCAL='A clean local commit or push is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR https://... checks green` using the existing PR full URL.'
      DOD_NO_MISTAKES_COMPLETE="The task is ready for validation only when committed at detached HEAD and pushed to the existing branch \`$TASK_BRANCH\`."
      DOD_NO_MISTAKES_HANDOFF="When you believe implementation is complete, committed, and pushed to the existing branch, append \`blocked: implemented, committed, and pushed, ready to validate\` and stop there; that handoff is a defined stopping point because firstmate must trigger validation before you run /no-mistakes - use \`blocked:\`, not \`$PAUSED_VERB:\`, which would defer recheck for an hour under away mode."
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_DONE='After /no-mistakes reports CI green for the existing PR (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR https://... checks green` using that PR full URL and stop. You are finished.'
      ;;
    no-mistakes:design)
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_INTRO='This ADR continues an existing PR through **no-mistakes**: `done:` means that PR is updated with checks green.'
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_LOCAL='A clean local ADR commit or push is NOT done, and neither is your own test run passing - this task has exactly one `done:` line and it is the last one, `done: PR https://... checks green` using the existing PR full URL.'
      DOD_NO_MISTAKES_COMPLETE="The ADR is ready for validation only when committed at detached HEAD and pushed to the existing branch \`$TASK_BRANCH\`."
      DOD_NO_MISTAKES_HANDOFF="When the ADR is complete, committed, and pushed to the existing branch, append \`$PAUSED_VERB: ADR complete, committed, and pushed, ready to validate\` and stop there; that handoff is a defined stopping point and a declared wait, and firstmate will then instruct you to run /no-mistakes to validate and update the existing ADR PR."
      # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
      DOD_NO_MISTAKES_DONE='After /no-mistakes reports CI green for the existing ADR PR (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR https://... checks green` using that PR full URL and stop. You are finished.'
      ;;
  esac
fi

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `'"$TASK_BRANCH"'` branch). Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
$DOD_DIRECT
$DOD_DIRECT_INTRO
$DOD_DIRECT_COMPLETE
$DOD_DIRECT_HANDOFF
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`$TASK_BRANCH\` branch; firstmate handles the merge into local \`main\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
$DOD_LOCAL
$DOD_LOCAL_INTRO
$DOD_LOCAL_COMPLETE
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
$DOD_LOCAL_HANDOFF
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
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
While you sit parked on a backgrounded \`axi run\` or \`axi respond\` call, rule 4's park-and-resume pairing applies: append \`$PAUSED_VERB:\` before you go idle and \`working:\` when the call returns.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
$DOD_NO_MISTAKES_ASK
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

$DOD_NO_MISTAKES_DONE
EOF
    ;;
esac

if [ "$CONTINUE_BRANCH_SET" -eq 1 ]; then
  if [ "$MODE" = local-only ]; then
    RULE1="1. Never push to any remote and never open a PR. Advance branch \`$TASK_BRANCH\` without checking it out; firstmate handles the merge into local \`main\`."
    IFS= read -r -d '' SETUP_BRANCH_STEP <<EOF || true
1. First action: continue existing branch \`$TASK_BRANCH\` from detached HEAD.
   Point this worktree at its tip without checking the branch out (\`git checkout --detach $TASK_BRANCH_SHELL\`).
   Do not \`git checkout $TASK_BRANCH_SHELL\`: a branch held by another worktree blocks checkout, not a ref update.
   Commit locally, then \`git update-ref $TASK_BRANCH_REF_SHELL HEAD\` advances that branch in place.
   Do not create \`fm/$ID\`.
EOF
  else
    IFS= read -r -d '' SETUP_BRANCH_STEP <<EOF || true
1. First action: continue existing branch \`$TASK_BRANCH\` from detached HEAD.
   Fetch the tip (\`git fetch origin $TASK_BRANCH_SHELL\`) and \`git checkout --detach FETCH_HEAD\`.
   Do not \`git checkout $TASK_BRANCH_SHELL\`: a branch held by another worktree blocks checkout, not push.
   Commit locally, then \`git push origin $TASK_BRANCH_PUSH_SHELL\` updates the existing PR in place.
   Do not create \`fm/$ID\`.
EOF
  fi
  SETUP_BRANCH_STEP=${SETUP_BRANCH_STEP%$'\n'}
else
  SETUP_BRANCH_STEP="1. First action: create your branch: \`git checkout -b fm/$ID\`"
fi

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

${FIRSTMATE_REPO_CREW_SECTION}# Task
{TASK}

<!-- firstmate-task-branch=$TASK_BRANCH -->
$ISSUE_SECTION$TRACKED_SECTIONS

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

$SETUP_BRANCH_STEP$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Your LATEST line is your entire visible state, so never leave a stale or stateless one standing.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a stopping point defined under Definition of done.
   Choose the verb by what clears the wait, not by whether you are idle.
   \`$PAUSED_VERB:\` is for a bounded external wait expected to clear on its own - an upstream release,
   a rate-limit reset, a scheduled window, or a backgrounded call you are parked on - for example
   \`$PAUSED_VERB: rate limit resets at 06:00 UTC\`.
   Firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of treating
   it as a possible wedge.
   \`blocked:\` is when firstmate must act before you can continue - for example
   \`blocked: implemented and committed, ready to validate\` when implementation is done and you
   need firstmate's validation trigger, or \`blocked: needs firstmate to steer past repeated failure\`.
   Wrong-verb cost: \`blocked:\` on a self-clearing wait is a cheap extra wake; \`$PAUSED_VERB:\` on a
   wait that needs firstmate can idle you for an hour under away mode before anyone rechecks.
   Park-and-resume pairing: whenever you background a pipeline call and go idle, append
   \`$PAUSED_VERB:\` BEFORE going idle and \`working:\` as soon as it returns - otherwise a spent
   \`needs-decision:\` stays standing and firstmate reads you as still waiting on a decision it
   already answered.
   Never poll with \`pgrep -f\` or \`pkill -f\` on a pattern that appears in your own command line - the wait matches itself and cannot exit.
   Wait on the actual PID, or run the command in the foreground; when killing, kill by PID.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
$DECISION_RULE
   \`resolved:\` carries NO state, so it must never be your last line: append the next state line
   (normally \`working:\`) in the same breath. A trailing \`resolved:\` makes you read as no state at
   all - invisible to firstmate and indistinguishable from a dead worker, which is worse than stale.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

$INBOX_SECTION

${BRAIN_SECTION}${PROJECT_MEMORY_SECTION}$DOD
EOF
echo "scaffolded: $BRIEF ($OUTPUT_KIND, mode=$MODE; replace {TASK})"
