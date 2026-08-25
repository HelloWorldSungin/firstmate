#!/usr/bin/env bash
# fm-gbrain-capture.sh - capture finished task knowledge into THIS home's brain.
#
# A completed task's knowledge must outlive the task. Teardown removes
# state/<id>.meta and the backlog prunes its Done row, so without this the only
# thing left is the durable outcome manifest and, for a scout, its report. This
# command turns those into a retrievable page in the home's own GBrain brain.
#
# Two properties are load-bearing and shape the whole design:
#
#   Capture is not lossy, and teardown is never blocked. The durable outbox
#   record is written synchronously BEFORE delivery is attempted and before
#   teardown removes anything, then delivery runs under a tight timeout and
#   warns rather than failing. Stopping GBrain mid-teardown therefore leaves a
#   pending item that `process` or `backfill` picks up later.
#
#   Redaction happens before enqueue, not before delivery. Once a body reaches
#   the outbox it is on disk, so bin/fm-gbrain-capture-lib.sh redacts and then
#   re-checks the redacted body, and a body that still carries credential-shaped
#   content is refused outright rather than stored.
#
# Capture is INERT until a home has a brain: with no initialized index this
# command does nothing, writes no receipt, and exits 0, so a fleet that has not
# adopted GBrain sees no behavior change at all.
#
# Usage:
#   fm-gbrain-capture.sh task <task-id> [--timeout <s>] [--require-brain]
#   fm-gbrain-capture.sh note --id <id> --title <t> (--file <p> | --stdin)
#                             [--project <p>] [--timeout <s>]
#   fm-gbrain-capture.sh process [--document <id>] [--limit <n>]
#                                [--timeout <s>] [--force]
#   fm-gbrain-capture.sh backfill [--limit <n>] [--timeout <s>] [--dry-run]
#   fm-gbrain-capture.sh audit [--json] [--timeout <s>]
#   fm-gbrain-capture.sh sweep [--timeout <s>] [--interval <s>] [--force]
#   fm-gbrain-capture.sh status [--json]
#   fm-gbrain-capture.sh show <document-id>
#
# Commands:
#   task      Compose one task's knowledge from its durable outcome manifest and
#             its report, enqueue it, then attempt bounded delivery and write the
#             capture receipt at state/<id>.gbrain. This is the lifecycle entry
#             point; bin/fm-teardown.sh calls it between publishing the manifest
#             and removing volatile state. It always exits 0 unless
#             --require-brain is given and this home has no brain.
#   note      Capture a durable note - the shape /stow uses for a pruned-but-
#             still-true learning or project gotcha. The body comes from a file
#             or stdin and goes through the same redaction and refusal path. It
#             is inert in a home with no brain; a refused body still exits
#             non-zero, because that is a finding about the note.
#   process   Retry pending outbox items, bounded by attempts and by --limit.
#             --force retries an item that has already exhausted its attempts,
#             and re-delivers one that is already captured.
#   backfill  Enqueue and deliver every task in data/ that has a manifest or a
#             report and is not already captured at its current content version.
#             A task whose durable source changed since its last delivery is
#             recomposed here and re-delivered to the same page, and counted and
#             named under refreshed once that delivery landed, so a sweep
#             reports drift it corrected rather than folding it into the
#             ordinary captured count or claiming a page it never reached.
#             Restartable: each item is durable and independent, so a run that
#             stops halfway loses nothing and a rerun resumes.
#   audit     Compare what the outbox says was captured against what the brain
#             actually serves. A record marked captured proves the page was once
#             accepted; it does not prove the page still exists, because a page
#             can be soft-deleted out of ordinary retrieval afterwards. This
#             names every such document, counts truncated bodies alongside it,
#             and exits non-zero when the two sides disagree. It refuses to call
#             a listing complete that came back exactly at its own limit, so a
#             capped read is reported as inconclusive rather than as a gap.
#   sweep     The structural re-capture trigger. A page goes stale when the
#             durable report it was composed from is edited after delivery, and
#             nothing about that edit reaches capture, because teardown already
#             ran. This recomposes every captured task, re-delivers the ones
#             whose content hash moved, and then audits stored against served.
#             It is inert and silent in a home with no brain, runs at most once
#             per --interval (default 6h) so a session start can arm it
#             unconditionally, and prints ONLY the lines an operator must act
#             on. --force ignores the interval. Exit is 0 when the sweep found
#             nothing to say, 1 when it printed something.
#   status    What is archived, pending, failed, unreadable, and what was
#             redacted. A refusal never becomes an outbox record, so it is not
#             here. Where a refusal IS reported differs per subcommand, and no
#             single rule covers all three, so read the one you called:
#               task      writes state/<id>.gbrain with status=skipped and the
#                         reason, warns on stderr, and exits 0, because capture
#                         must never be able to fail a teardown. --require-brain
#                         is the opt-in that makes a missing brain fatal.
#               backfill  writes the same per-task receipt, prints
#                         "refused <id>: <reason>" on STDOUT in its run summary,
#                         counts it under refused rather than errors, and exits
#                         0, for the same reason.
#               note      writes NO receipt, because a receipt is keyed to a
#                         task id and a note has none. It prints the reason on
#                         stderr and exits non-zero: a refused note is a real
#                         failure and nothing downstream needs it to succeed.
#             /stow calls note, so /stow reads a refusal from that non-zero exit
#             and stderr. Do not collapse these into one rule: the receipt does
#             not exist for note, and the exit status does not move for task or
#             backfill.
#   show      One outbox record, body included.
#
# Environment:
#   FM_HOME                          active firstmate home
#   FM_GBRAIN_BIN                    gbrain executable (default: gbrain on PATH)
#   FM_GBRAIN_CAPTURE_TIMEOUT        seconds allowed per delivery (default: 20)
#   FM_GBRAIN_CAPTURE_MAX_ATTEMPTS   attempts before an item is failed (default: 5)
#   FM_GBRAIN_CAPTURE_MAX_BYTES      cap on a captured body (default: 65536)
#   FM_GBRAIN_CAPTURE_AUDIT_MAX_PAGES  ceiling on one audit listing (default:
#                                    4000); a listing that returns exactly this
#                                    many rows is reported as inconclusive
#   FM_GBRAIN_CAPTURE_SWEEP_INTERVAL seconds between sweeps (default: 21600)
#
# docs/gbrain-capture.md owns the contract; bin/fm-gbrain-capture-lib.sh owns
# identity, redaction, and the outbox wire shape.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-gbrain-capture-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-gbrain-capture-lib.sh"

GBRAIN_BIN="${FM_GBRAIN_BIN:-gbrain}"
CAPTURE_TIMEOUT=${FM_GBRAIN_CAPTURE_TIMEOUT:-20}

usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }
die() { printf 'fm-gbrain-capture: %s\n' "$1" >&2; exit 1; }
warn() { printf 'fm-gbrain-capture: %s\n' "$1" >&2; }

command -v jq >/dev/null 2>&1 || die "jq is not installed"

# --- brain readiness --------------------------------------------------------

BRAIN_HOME_DIR=""
BRAIN_EMBED_URL=""

# A home has a brain when its configuration is valid and its index directory
# exists. An index that has never been initialized is not an error here: it is
# the ordinary state of a home that has not adopted GBrain, and capture stays
# inert for it.
brain_ready() {  # -> 0 ready, 1 not ready (reason in FM_GBRAIN_CAPTURE_ERROR)
  local shared
  shared=$(fm_gbrain_shared_path "$FM_HOME")
  fm_gbrain_validate_shared "$shared" || { FM_GBRAIN_CAPTURE_ERROR=$FM_GBRAIN_ERROR; return 1; }
  # bin/fm-gbrain-lib.sh is the single owner of where a home's brain lives, so
  # its answer is used as given: a second derivation here would let this command
  # look for an index somewhere bin/fm-gbrain.sh never creates one.
  fm_gbrain_resolve_paths "$FM_HOME" || { FM_GBRAIN_CAPTURE_ERROR=$FM_GBRAIN_ERROR; return 1; }
  BRAIN_HOME_DIR=$FM_GBRAIN_HOME_DIR
  BRAIN_EMBED_URL=$(fm_gbrain_json_str "$shared" '.local.embedding_base_url')
  [ -d "$FM_GBRAIN_PGLITE" ] || { FM_GBRAIN_CAPTURE_ERROR="this home has no initialized brain at $FM_GBRAIN_PGLITE"; return 1; }
  return 0
}

# --- bounded delivery -------------------------------------------------------

# Every branch escalates to SIGKILL, because SIGTERM alone is not a bound: a
# gbrain that ignores it, or that is stuck in uninterruptible IO on a locked
# PGLite index, would keep a lifecycle-critical path parked forever. The other
# call on that same path - teardown's usage refresh - takes the same guarantee
# from fm_run_timed in bin/fm-timeout-lib.sh.
FM_GBRAIN_CAPTURE_KILL_GRACE=5

run_bounded() {  # <seconds> <cmd...>
  local seconds=$1
  shift
  if [ "${FM_GBRAIN_CAPTURE_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout -k "$FM_GBRAIN_CAPTURE_KILL_GRACE" "$seconds" "$@"
  elif [ "${FM_GBRAIN_CAPTURE_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k "$FM_GBRAIN_CAPTURE_KILL_GRACE" "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
      "$seconds" "$@"
  else
    warn "no timeout implementation on PATH; refusing an unbounded delivery"
    return 125
  fi
}

# Every gbrain call this command makes goes through here, so the brain a call
# reaches is decided in ONE place: the index comes from GBRAIN_HOME, and the
# embedding endpoint is passed per call because GBrain does not persist a
# command-scoped one. Callers invoke it inside a command substitution, so the
# exports are scoped to that subshell and never reach the rest of the run.
run_gbrain() {  # <timeout> <gbrain-args...>
  local seconds=$1
  shift
  export GBRAIN_HOME="$BRAIN_HOME_DIR"
  [ -n "$BRAIN_EMBED_URL" ] && export OLLAMA_BASE_URL="$BRAIN_EMBED_URL"
  run_bounded "$seconds" "$GBRAIN_BIN" "$@"
}

# Deliver one body to THIS home's brain under the caller's timeout. The slug is
# supplied, so GBrain updates the same page every time: repeated delivery of the
# same logical document can never create a second one.
#
# The reference comes from GBrain's own structured receipt rather than from its
# human-readable output: in 0.42.69.0 `--quiet` prints a labelled block rather
# than a bare slug, so a line-shaped heuristic would happily record the label.
# An unparseable receipt is a failed delivery, never a guessed one.
#
# Prints the page reference GBrain returned on stdout. Returns non-zero with the
# reason on stderr.
deliver() {  # <slug> <body-file> <page-type> <timeout>
  local slug=$1 body=$2 type=$3 seconds=$4 out rc=0
  command -v "$GBRAIN_BIN" >/dev/null 2>&1 || { echo "gbrain is not installed (set FM_GBRAIN_BIN)" >&2; return 1; }
  out=$(run_gbrain "$seconds" capture --file "$body" --slug "$slug" --type "$type" --json 2>&1) || rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "delivery did not finish within ${seconds}s" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tr -s '[:space:]' ' ' | cut -c1-200 >&2
    return 1
  fi
  local page
  # Import warnings precede the receipt on the same stream, so the document is
  # taken from the first '{' onward rather than from the whole output.
  page=$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*{/,$p' | jq -r '.slug // empty' 2>/dev/null)
  if [ -z "$page" ]; then
    echo "gbrain returned no page reference for $slug" >&2
    return 1
  fi
  printf '%s\n' "$page"
}

# --- capture receipt --------------------------------------------------------

# state/<id>.gbrain, in the key=value shape bin/fm-outcome-lib.sh reads. Written
# BEFORE the manifest is republished, which is the only reason a torn-down
# task's manifest can carry its capture state at all.
write_receipt() {  # <task-id> <status> <receipt> <detail>
  local id=$1 status=$2 receipt=$3 detail=$4 path tmp
  path=$(fm_gbrain_capture_receipt_path "$STATE" "$id")
  mkdir -p "$STATE" 2>/dev/null || true
  tmp=$(mktemp "$STATE/.fm-gbrain-receipt.XXXXXX") || return 1
  {
    printf 'status=%s\n' "$status"
    [ -n "$receipt" ] && printf 'receipt=%s\n' "$receipt"
    printf 'observed_at=%s\n' "$(fm_gbrain_capture_now_iso)"
    [ -n "$detail" ] && printf 'detail=%s\n' "$(printf '%s' "$detail" | tr -d '\n' | cut -c1-200)"
    # A skipped optional line must not become the group's exit status.
    true
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# --- body composition -------------------------------------------------------
#
# The composer's inputs are ENUMERATED, which is how "no raw tool arguments, no
# environment values, no private file excerpts" is a property rather than a
# promise: it reads the durable outcome manifest (already key-allowlisted by
# bin/fm-outcome-lib.sh) and the task's own report, and nothing else. It never
# opens a brief, a prompt, a transcript, a credential store, a configuration
# file, or anything under a project.

manifest_path() { printf '%s/%s/outcome.json\n' "$DATA" "$1"; }
report_path() { printf '%s/%s/report.md\n' "$DATA" "$1"; }

# The backslash is escaped BEFORE the quote, so the escape this adds is not
# itself re-escaped. Both matter inside a double-quoted YAML scalar: a title
# containing "C:\Users" would otherwise read as a unicode escape, and one ending
# in a backslash would escape the closing quote and swallow the lines after it.
yaml_scalar() {  # <value> -> a safely quoted single-line YAML scalar
  local v=$1
  v=$(printf '%s' "$v" | tr -d '\n\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '"%s"' "$v"
}

# Compose one task document. Prints the title on stdout and writes the body to
# <out>. Returns 1 when the task has nothing durable to capture.
compose_task_body() {  # <task-id> <out>
  local id=$1 out=$2 manifest report title project kind mode outcome detail
  local completed pr report_present
  manifest=$(manifest_path "$id")
  report=$(report_path "$id")
  report_present=0
  [ -f "$report" ] && [ ! -L "$report" ] && report_present=1
  if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
    [ "$report_present" -eq 1 ] || return 1
  fi

  local doc='{}'
  if [ -f "$manifest" ] && [ ! -L "$manifest" ]; then
    doc=$(jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 && cat "$manifest") || doc='{}'
  fi
  title=$(printf '%s' "$doc" | jq -r '.title // empty')
  project=$(printf '%s' "$doc" | jq -r '.project // empty')
  kind=$(printf '%s' "$doc" | jq -r '.kind // empty')
  mode=$(printf '%s' "$doc" | jq -r '.mode // empty')
  outcome=$(printf '%s' "$doc" | jq -r '.outcome.state // empty')
  detail=$(printf '%s' "$doc" | jq -r '.outcome.detail // empty')
  completed=$(printf '%s' "$doc" | jq -r '.timestamps.completed // empty')
  pr=$(printf '%s' "$doc" | jq -r '.pr.url // empty')
  [ -n "$title" ] || title="task $id"

  {
    printf -- '---\n'
    printf 'title: %s\n' "$(yaml_scalar "$title")"
    printf 'type: firstmate-task\n'
    printf 'tags: [firstmate, firstmate-task%s%s]\n' \
      "${kind:+, }${kind}" "${project:+, }$(printf '%s' "${project##*/}" | tr -c 'A-Za-z0-9._-' '-')"
    printf 'firstmate_schema: %s\n' "$FM_GBRAIN_CAPTURE_SCHEMA"
    printf 'firstmate_task_id: %s\n' "$id"
    printf 'firstmate_home: %s\n' "$(yaml_scalar "$FM_HOME")"
    [ -n "$project" ] && printf 'firstmate_project: %s\n' "$(yaml_scalar "$project")"
    [ -n "$completed" ] && printf 'firstmate_completed: %s\n' "$completed"
    printf -- '---\n\n'
    printf '# %s\n\n' "$title"
    # shellcheck disable=SC2016  # backticks are markdown code spans, not a command substitution
    printf -- '- Task: `%s`\n' "$id"
    # shellcheck disable=SC2016
    [ -n "$project" ] && printf -- '- Project: `%s`\n' "$project"
    [ -n "$kind" ] && printf -- '- Kind: %s%s\n' "$kind" "${mode:+ (${mode})}"
    [ -n "$outcome" ] && printf -- '- Outcome: %s\n' "$outcome"
    [ -n "$completed" ] && printf -- '- Completed: %s\n' "$completed"
    [ -n "$pr" ] && printf -- '- Pull request: %s\n' "$pr"
    printf '%s' "$doc" | jq -r '(.work_items.references // [])[] | "- Work item: " + (.url // "")' 2>/dev/null
    printf '\n'
    if [ -n "$detail" ]; then
      printf '## Outcome\n\n%s\n\n' "$detail"
    fi
    if [ "$report_present" -eq 1 ]; then
      printf '## Report\n\n'
      head -c "$FM_GBRAIN_CAPTURE_MAX_BYTES" "$report"
      printf '\n'
    fi
  } > "$out" || return 1
  printf '%s\n' "$title"
}

# --- outbox operations ------------------------------------------------------

# Build and store one record, setting ENQUEUED_DOC_ID. Returns 1 when the
# redaction guard refused the body, 2 on an internal failure, with the reason in
# FM_GBRAIN_CAPTURE_ERROR. It deliberately reports through variables rather than
# stdout: a command substitution would run the build in a subshell and lose
# every refusal reason it is supposed to surface.
ENQUEUED_DOC_ID=""
enqueue() {  # <kind> <source-id> <title> <raw-body-file>
  local kind=$1 source_id=$2 title=$3 raw=$4 tag doc_id previous staged rc=0
  ENQUEUED_DOC_ID=""
  tag=$(fm_gbrain_capture_home_tag "$FM_HOME")
  doc_id=$(fm_gbrain_capture_document_id "$tag" "$kind" "$source_id")
  previous=$(fm_gbrain_capture_item_read "$DATA" "$doc_id" 2>/dev/null) || previous=""
  staged=$(mktemp) || { fm_gbrain_capture_fail "could not stage the outbox record"; return 2; }
  fm_gbrain_capture_item_build "$FM_HOME" "$kind" "$source_id" "$title" "$raw" "$staged" "$previous" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$staged"
    return "$rc"
  fi
  if ! fm_gbrain_capture_item_write "$DATA" "$doc_id" "$(cat "$staged")"; then
    rm -f "$staged"
    fm_gbrain_capture_fail "could not write the outbox record for $doc_id"
    return 2
  fi
  rm -f "$staged"
  ENQUEUED_DOC_ID=$doc_id
}

item_update() {  # <document-id> <jq-filter> <jq-args...>
  local doc_id=$1 filter=$2
  shift 2
  local current updated
  current=$(fm_gbrain_capture_item_read "$DATA" "$doc_id") || return 1
  updated=$(printf '%s' "$current" | jq "$@" "$filter") || return 1
  fm_gbrain_capture_item_write "$DATA" "$doc_id" "$updated"
}

# Deliver one stored record. Prints one summary line. Returns 0 when the item
# ends captured, 1 otherwise; a caller on a lifecycle path ignores that and
# continues either way.
process_item() {  # <document-id> <timeout> <force>
  local doc_id=$1 seconds=$2 force=$3 item status attempts slug kind body page now rc=0
  item=$(fm_gbrain_capture_item_read "$DATA" "$doc_id") || {
    printf '%s unreadable\n' "$doc_id"
    return 1
  }
  status=$(printf '%s' "$item" | jq -r '.status')
  attempts=$(printf '%s' "$item" | jq -r '.attempts')
  slug=$(printf '%s' "$item" | jq -r '.slug')
  kind=$(printf '%s' "$item" | jq -r '.source.kind')
  if [ "$status" = captured ] && [ "$force" != 1 ]; then
    printf '%s captured\n' "$doc_id"
    return 0
  fi
  if [ "$status" = failed ] && [ "$force" != 1 ]; then
    printf '%s failed (attempts exhausted; --force to retry)\n' "$doc_id"
    return 1
  fi

  local errfile err=""
  body=$(mktemp) || return 1
  errfile=$(mktemp) || { rm -f "$body"; return 1; }
  printf '%s' "$item" | jq -r '.body' > "$body" || { rm -f "$body" "$errfile"; return 1; }
  page=$(deliver "$slug" "$body" "firstmate-$kind" "$seconds" 2>"$errfile") || rc=$?
  err=$(tr -s '[:space:]' ' ' < "$errfile" | cut -c1-200)
  rm -f "$body" "$errfile"
  now=$(fm_gbrain_capture_now_iso)
  if [ "$rc" -eq 0 ] && [ -n "$page" ]; then
    # shellcheck disable=SC2016  # jq program text; $a/$page/$now are jq variables
    item_update "$doc_id" '.status = "captured" | .attempts = ($a | tonumber) | .last_error = null
      | .gbrain_document = $page | .captured_at = $now | .updated_at = $now' \
      --arg a "$((attempts + 1))" --arg page "$page" --arg now "$now" || return 1
    printf '%s captured %s\n' "$doc_id" "$page"
    return 0
  fi
  attempts=$((attempts + 1))
  local next=pending
  [ "$attempts" -ge "$FM_GBRAIN_CAPTURE_MAX_ATTEMPTS" ] && next=failed
  # shellcheck disable=SC2016  # jq program text; $s/$a/$e/$now are jq variables
  item_update "$doc_id" '.status = $s | .attempts = ($a | tonumber) | .last_error = $e | .updated_at = $now' \
    --arg s "$next" --arg a "$attempts" --arg e "${err:-delivery failed}" --arg now "$now" || return 1
  printf '%s %s %s\n' "$doc_id" "$next" "${err:-delivery failed}"
  return 1
}

list_items() {  # -> every stored document id, in stable order
  local dir
  dir=$(fm_gbrain_capture_outbox_dir "$DATA")
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
    | sed 's|.*/||; s|\.json$||' | sort
}

# --- commands ---------------------------------------------------------------

cmd_task() {
  local id="" seconds=$CAPTURE_TIMEOUT require=0
  while [ $# -gt 0 ]; do
    case $1 in
      --timeout) seconds=${2:-}; shift 2 ;;
      --require-brain) require=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [ -n "$id" ] && die "unexpected argument: $1"; id=$1; shift ;;
    esac
  done
  [ -n "$id" ] || die "usage: fm-gbrain-capture.sh task <task-id>"
  fm_gbrain_capture_source_id_valid "$id" || die "unsafe task id: $id"
  case "$seconds" in ''|*[!0-9]*|0) die "--timeout takes a positive number of seconds" ;; esac

  if ! brain_ready; then
    [ "$require" -eq 1 ] && die "$FM_GBRAIN_CAPTURE_ERROR"
    # Inert by design: no brain means no outbox, no receipt, and no trace in the
    # manifest, so a fleet that has not adopted GBrain is untouched.
    return 0
  fi

  local raw title doc_id rc=0
  raw=$(mktemp) || return 0
  title=$(compose_task_body "$id" "$raw") || {
    rm -f "$raw"
    [ "$require" -eq 1 ] && die "task $id has no durable manifest or report to capture"
    return 0
  }
  enqueue task "$id" "$title" "$raw" || rc=$?
  doc_id=$ENQUEUED_DOC_ID
  rm -f "$raw"
  if [ "$rc" -eq 1 ]; then
    write_receipt "$id" skipped "" "$FM_GBRAIN_CAPTURE_ERROR" || true
    warn "$FM_GBRAIN_CAPTURE_ERROR"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    # An internal failure is neither a policy refusal nor a queued item, so it
    # is recorded as failed rather than left looking like no provider ran.
    write_receipt "$id" failed "" "${FM_GBRAIN_CAPTURE_ERROR:-internal error}" || true
    warn "could not enqueue $id: ${FM_GBRAIN_CAPTURE_ERROR:-internal error}"
    return 0
  fi

  # The record is durable from here on, so every later failure is a retry rather
  # than a loss.
  local line item status page detail
  line=$(process_item "$doc_id" "$seconds" 0) || true
  item=$(fm_gbrain_capture_item_read "$DATA" "$doc_id") || item='{}'
  status=$(printf '%s' "$item" | jq -r '.status // "pending"')
  # The receipt always names the page address, even when delivery has not
  # happened yet: the address is deterministic, so a manifest published while an
  # item is still pending still points at where the document will live.
  page=$(printf '%s' "$item" | jq -r '.gbrain_document // .slug // ""')
  detail=$(printf '%s' "$item" | jq -r '(.revision_id // "") + (if .last_error then "; " + .last_error else "" end)')
  write_receipt "$id" "$status" "$page" "$detail" || warn "could not write the capture receipt for $id"
  [ "$status" = captured ] || warn "$line"
  return 0
}

cmd_note() {
  local id="" title="" file="" use_stdin=0 project="" seconds=$CAPTURE_TIMEOUT
  while [ $# -gt 0 ]; do
    case $1 in
      --id) id=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --file) file=${2:-}; shift 2 ;;
      --stdin) use_stdin=1; shift ;;
      --project) project=${2:-}; shift 2 ;;
      --timeout) seconds=${2:-}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$id" ] || die "note needs --id <id>"
  [ -n "$title" ] || die "note needs --title <title>"
  fm_gbrain_capture_source_id_valid "$id" || die "unsafe note id: $id"
  case "$seconds" in ''|*[!0-9]*|0) die "--timeout takes a positive number of seconds" ;; esac
  if [ "$use_stdin" -eq 0 ]; then
    [ -n "$file" ] || die "note needs --file <path> or --stdin"
    [ -f "$file" ] && [ ! -L "$file" ] || die "no readable note body at $file"
  fi
  # Inert in a home with no brain, exactly as `task` is, so a routing step that
  # offers to store a note is a complete no-op rather than an error to report.
  if ! brain_ready; then
    warn "$FM_GBRAIN_CAPTURE_ERROR; nothing was stored"
    return 0
  fi

  local raw rc=0 doc_id
  raw=$(mktemp) || die "could not stage the note body"
  {
    printf -- '---\n'
    printf 'title: %s\n' "$(yaml_scalar "$title")"
    printf 'type: firstmate-note\n'
    printf 'tags: [firstmate, firstmate-note]\n'
    printf 'firstmate_schema: %s\n' "$FM_GBRAIN_CAPTURE_SCHEMA"
    printf 'firstmate_note_id: %s\n' "$id"
    printf 'firstmate_home: %s\n' "$(yaml_scalar "$FM_HOME")"
    [ -n "$project" ] && printf 'firstmate_project: %s\n' "$(yaml_scalar "$project")"
    printf -- '---\n\n'
    printf '# %s\n\n' "$title"
    if [ "$use_stdin" -eq 1 ]; then cat; else cat "$file"; fi
    printf '\n'
  } > "$raw"
  enqueue note "$id" "$title" "$raw" || rc=$?
  doc_id=$ENQUEUED_DOC_ID
  rm -f "$raw"
  [ "$rc" -eq 0 ] || die "${FM_GBRAIN_CAPTURE_ERROR:-could not enqueue the note}"
  process_item "$doc_id" "$seconds" 0 || true
}

cmd_process() {
  local doc="" limit=0 seconds=$CAPTURE_TIMEOUT force=0
  while [ $# -gt 0 ]; do
    case $1 in
      --document) doc=${2:-}; shift 2 ;;
      --limit) limit=${2:-}; shift 2 ;;
      --timeout) seconds=${2:-}; shift 2 ;;
      --force) force=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$seconds" in ''|*[!0-9]*|0) die "--timeout takes a positive number of seconds" ;; esac
  case "$limit" in ''|*[!0-9]*) die "--limit takes a number" ;; esac
  brain_ready || die "$FM_GBRAIN_CAPTURE_ERROR"

  local captured=0 remaining=0 n=0 id
  if [ -n "$doc" ]; then
    fm_gbrain_capture_document_id_valid "$doc" || die "unsafe document id: $doc"
    process_item "$doc" "$seconds" "$force" && captured=1 || remaining=1
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ "$limit" -gt 0 ] && [ "$n" -ge "$limit" ] && break
      n=$((n + 1))
      if process_item "$id" "$seconds" "$force"; then captured=$((captured + 1)); else remaining=$((remaining + 1)); fi
    done <<EOF
$(list_items)
EOF
  fi
  printf 'processed captured=%d not-captured=%d\n' "$captured" "$remaining"
  [ "$remaining" -eq 0 ]
}

# One owner for the line a session start relays verbatim, so the claim it makes
# cannot be printed from a place that does not yet know the delivery landed.
report_refreshed() {  # <task-id>
  printf 'refreshed %s: the durable source changed since its page was written\n' "$1"
}

# Restartable by construction: every enqueue and every delivery is its own
# durable transaction, so a run that is interrupted resumes with no bookkeeping
# beyond the outbox records themselves.
cmd_backfill() {
  local limit=0 seconds=$CAPTURE_TIMEOUT dry=0
  while [ $# -gt 0 ]; do
    case $1 in
      --limit) limit=${2:-}; shift 2 ;;
      --timeout) seconds=${2:-}; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$seconds" in ''|*[!0-9]*|0) die "--timeout takes a positive number of seconds" ;; esac
  case "$limit" in ''|*[!0-9]*) die "--limit takes a number" ;; esac
  brain_ready || die "$FM_GBRAIN_CAPTURE_ERROR"

  local scanned=0 enqueued=0 captured=0 already=0 refused=0 errors=0 refreshed=0 n=0
  local dir id raw title doc_id rc item before_version after_version drifted
  for dir in "$DATA"/*/; do
    [ -d "$dir" ] || continue
    id=${dir%/}
    id=${id##*/}
    fm_gbrain_capture_source_id_valid "$id" || continue
    { [ -f "$dir/outcome.json" ] || [ -f "$dir/report.md" ]; } || continue
    scanned=$((scanned + 1))
    [ "$limit" -gt 0 ] && [ "$n" -ge "$limit" ] && continue
    raw=$(mktemp) || { errors=$((errors + 1)); continue; }
    if ! title=$(compose_task_body "$id" "$raw"); then
      rm -f "$raw"
      continue
    fi
    if [ "$dry" -eq 1 ]; then
      rm -f "$raw"
      n=$((n + 1))
      printf 'would capture %s\n' "$id"
      continue
    fi
    rc=0
    # Read BEFORE the enqueue overwrites it: the recomposed content version is
    # the whole drift signal, and after the write there is nothing left to
    # compare against. This is the structural re-capture trigger - a durable
    # source edited after its page was written produces a different hash here,
    # and the same slug updates the same page.
    before_version=$(fm_gbrain_capture_item_read "$DATA" \
      "$(fm_gbrain_capture_document_id "$(fm_gbrain_capture_home_tag "$FM_HOME")" task "$id")" 2>/dev/null \
      | jq -r '.content_version // ""') || before_version=""
    enqueue task "$id" "$title" "$raw" || rc=$?
    doc_id=$ENQUEUED_DOC_ID
    rm -f "$raw"
    if [ "$rc" -eq 1 ]; then
      refused=$((refused + 1))
      printf 'refused %s: %s\n' "$id" "$FM_GBRAIN_CAPTURE_ERROR"
      write_receipt "$id" skipped "" "$FM_GBRAIN_CAPTURE_ERROR" || true
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      errors=$((errors + 1))
      printf 'error %s: %s\n' "$id" "${FM_GBRAIN_CAPTURE_ERROR:-internal error}"
      continue
    fi
    n=$((n + 1))
    enqueued=$((enqueued + 1))
    item=$(fm_gbrain_capture_item_read "$DATA" "$doc_id") || item='{}'
    after_version=$(printf '%s' "$item" | jq -r '.content_version // ""')
    drifted=0
    if [ -n "$before_version" ] && [ "$before_version" != "$after_version" ]; then
      drifted=1
    fi
    # Already captured at this exact content version: a rerun re-delivers
    # nothing, which is what makes the whole sweep cheap to restart.
    if [ "$(printf '%s' "$item" | jq -r '.status // ""')" = captured ]; then
      already=$((already + 1))
      if [ "$drifted" -eq 1 ]; then
        refreshed=$((refreshed + 1))
        report_refreshed "$id"
      fi
      continue
    fi
    # Claimed only once the delivery that makes it true has happened: a session
    # start relays this line verbatim as completed work, so a sweep whose
    # delivery failed must not say the page is true again while it is still
    # serving the body the durable source moved away from.
    if process_item "$doc_id" "$seconds" 0 >/dev/null; then
      captured=$((captured + 1))
      if [ "$drifted" -eq 1 ]; then
        refreshed=$((refreshed + 1))
        report_refreshed "$id"
      fi
    else
      errors=$((errors + 1))
    fi
    item=$(fm_gbrain_capture_item_read "$DATA" "$doc_id") || item='{}'
    write_receipt "$id" \
      "$(printf '%s' "$item" | jq -r '.status // "pending"')" \
      "$(printf '%s' "$item" | jq -r '.gbrain_document // .slug // ""')" \
      "$(printf '%s' "$item" | jq -r '(.revision_id // "") + (if .last_error then "; " + .last_error else "" end)')" || true
  done
  printf 'backfill scanned=%d enqueued=%d captured=%d already-captured=%d refreshed=%d refused=%d errors=%d\n' \
    "$scanned" "$enqueued" "$captured" "$already" "$refreshed" "$refused" "$errors"
  [ "$errors" -eq 0 ]
}

# The outbox holds one record per completed task and grows with the fleet's
# history, so the listing is built in ONE jq pass over every file rather than by
# re-serializing an accumulator per record. A record jq cannot read is projected
# as "unreadable" instead of dropped, because a listing that silently omits a
# damaged record reads as "nothing to do".
status_documents() {  # -> one JSON array of every stored record, body removed
  local docs id item
  docs=$(
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      printf '%s\n' "$id"
    done <<EOF
$(list_items)
EOF
  )
  if [ -z "$docs" ]; then
    docs='[]'
  else
    docs=$(printf '%s\n' "$docs" | while IFS= read -r id; do
      # item_read validates before it prints, so a non-empty result is known
      # good and an empty one is known bad; neither depends on how jq happens
      # to treat empty input.
      item=$(fm_gbrain_capture_item_read "$DATA" "$id" 2>/dev/null) || item=""
      if [ -n "$item" ]; then
        printf '%s' "$item" | jq -c 'del(.body)'
      else
        jq -cn --arg id "$id" '{document_id: $id, status: "unreadable", source: {kind: "task", id: $id}, redactions: []}'
      fi
    done | jq -s '.')
  fi
  printf '%s' "$docs"
}

cmd_status() {
  local json_mode=0 docs
  [ "${1:-}" = --json ] && json_mode=1
  docs=$(status_documents)
  if [ "$json_mode" -eq 1 ]; then
    printf '%s' "$docs" | jq '{
      schema: "fm-gbrain-capture-status.v1",
      totals: {
        archived: (map(select(.status == "captured")) | length),
        pending: (map(select(.status == "pending")) | length),
        failed: (map(select(.status == "failed")) | length),
        unreadable: (map(select(.status == "unreadable")) | length),
        truncated: (map(select(.truncated == true)) | length),
        redacted_values: (map(.redactions // [] | map(.count) | add // 0) | add // 0)
      },
      documents: .
    }'
    return 0
  fi
  printf '%s' "$docs" | jq -r '
    "archived   \(map(select(.status == "captured")) | length)",
    "pending    \(map(select(.status == "pending")) | length)",
    "failed     \(map(select(.status == "failed")) | length)",
    "unreadable \(map(select(.status == "unreadable")) | length)",
    "truncated  \(map(select(.truncated == true)) | length) cut at the capture cap",
    "redacted   \(map(.redactions // [] | map(.count) | add // 0) | add // 0) value(s)",
    (.[] | "  \(.status)\t\(.document_id)\t\((.redactions // []) | map("\(.class)x\(.count)") | join(",") // "")\(if .last_error then "\t" + .last_error else "" end)")
  '
}

# --- stored-versus-active audit ---------------------------------------------
#
# An outbox record marked captured proves the page was ACCEPTED once. It does
# not prove the page still exists: GBrain soft-deletes, and a soft-deleted row
# is absent from ordinary retrieval while the record that produced it still
# reads as archived. The two sides therefore have to be compared against each
# other, and the comparison has to be able to say "I could not tell".

FM_GBRAIN_CAPTURE_AUDIT_SCHEMA=fm-gbrain-capture-audit.v1
AUDIT_MAX_PAGES=${FM_GBRAIN_CAPTURE_AUDIT_MAX_PAGES:-4000}

# The audit's durable result, so the surfaces that report a gap - the dashboard
# panel and the session-start sweep - read one observation instead of each
# opening the index on its own poll. Its schema is this command's output.
audit_record_path() { printf '%s/.gbrain-audit\n' "$STATE"; }

# The pages the index actually serves for THIS home, one slug per line, with the
# row count left in AUDIT_ROWS.
#
# The listing is asked for as one bounded page rather than walked: GBrain's own
# guidance is that a result returned at exactly the requested limit may be
# truncated, so a short result is proof of completeness and a result at the
# limit is refused as evidence rather than read as a gap. Only rows carrying a
# tab-separated slug are counted, because the CLI also writes upgrade notices to
# this stream.
AUDIT_ROWS=0
list_active_slugs() {  # <timeout> <slug-prefix>
  local seconds=$1 prefix=$2 out rc=0 rows
  command -v "$GBRAIN_BIN" >/dev/null 2>&1 || {
    echo "gbrain is not installed (set FM_GBRAIN_BIN)" >&2
    return 1
  }
  out=$(run_gbrain "$seconds" list --limit "$AUDIT_MAX_PAGES" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "the index listing did not finish within ${seconds}s" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "the index listing failed (gbrain list exited $rc)" >&2
    return 1
  fi
  rows=$(printf '%s\n' "$out" | awk -F'\t' 'NF >= 2 && $1 != "" { n++ } END { print n + 0 }')
  AUDIT_ROWS=$rows
  printf '%s\n' "$out" | awk -F'\t' -v p="$prefix" 'NF >= 2 && index($1, p) == 1 { print $1 }' | sort -u
}

cmd_audit() {
  local json_mode=0 seconds=$CAPTURE_TIMEOUT
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json_mode=1; shift ;;
      --timeout) seconds=${2:-}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$seconds" in ''|*[!0-9]*|0) die "--timeout takes a positive number of seconds" ;; esac
  brain_ready || die "$FM_GBRAIN_CAPTURE_ERROR"

  local tag prefix docs stored_file active_file missing_file
  local stored truncated active missing state detail="" listing_error=""
  tag=$(fm_gbrain_capture_home_tag "$FM_HOME")
  prefix="firstmate/$tag/"
  docs=$(status_documents)
  stored_file=$(mktemp) || die "could not stage the audit"
  active_file=$(mktemp) || { rm -f "$stored_file"; die "could not stage the audit"; }
  missing_file=$(mktemp) || { rm -f "$stored_file" "$active_file"; die "could not stage the audit"; }
  printf '%s' "$docs" | jq -r '.[] | select(.status == "captured") | .slug' | sort -u > "$stored_file"
  stored=$(grep -c . < "$stored_file" | tr -cd '0-9')
  truncated=$(printf '%s' "$docs" | jq '[.[] | select(.truncated == true)] | length')

  if list_active_slugs "$seconds" "$prefix" > "$active_file" 2>"$missing_file"; then
    listing_error=""
  else
    listing_error=$(tr -s '[:space:]' ' ' < "$missing_file" | cut -c1-200)
    : > "$active_file"
  fi
  active=$(grep -c . < "$active_file" | tr -cd '0-9')
  comm -23 "$stored_file" "$active_file" > "$missing_file"
  missing=$(grep -c . < "$missing_file" | tr -cd '0-9')

  # Fail closed in both directions a listing can lie: a listing that did not
  # complete proves nothing, and a listing returned at exactly its own ceiling
  # may have dropped the very pages this is looking for. Neither is reported as
  # a gap, because a false gap is what would train an operator to ignore a real
  # one.
  if [ -n "$listing_error" ]; then
    state=inconclusive
    missing=0
    detail="the index could not be listed, so nothing was compared: $listing_error"
    : > "$missing_file"
  elif [ "$AUDIT_ROWS" -ge "$AUDIT_MAX_PAGES" ]; then
    state=inconclusive
    missing=0
    detail="the index listing came back at its $AUDIT_MAX_PAGES-row ceiling, so it may be incomplete; raise FM_GBRAIN_CAPTURE_AUDIT_MAX_PAGES and run the audit again"
    : > "$missing_file"
  elif [ "$missing" -gt 0 ]; then
    state=gap
    detail="$missing captured document(s) are absent from the active index; recapture a task with backfill and a note with process --document <document-id> --force, or restore them in GBrain if they were deleted deliberately"
  else
    state=ok
    detail="every captured document is served by the active index"
  fi

  local document
  document=$(jq -n \
    --arg schema "$FM_GBRAIN_CAPTURE_AUDIT_SCHEMA" \
    --arg generated "$(fm_gbrain_capture_now_iso)" \
    --arg home "$FM_HOME" \
    --arg state "$state" \
    --arg detail "$detail" \
    --argjson stored "${stored:-0}" \
    --argjson active "${active:-0}" \
    --argjson missing "${missing:-0}" \
    --argjson truncated "$truncated" \
    --rawfile missing_slugs "$missing_file" '
      {schema: $schema, generated: $generated, home: $home, state: $state,
       stored: $stored, active: $active, missing: $missing, truncated: $truncated,
       missing_slugs: ($missing_slugs | split("\n") | map(select(length > 0))),
       detail: $detail}')
  rm -f "$stored_file" "$active_file" "$missing_file"

  # Written before it is printed, so a caller that only reads the durable record
  # sees this run even if its own stdout is discarded.
  local tmp path
  path=$(audit_record_path)
  mkdir -p "$STATE" 2>/dev/null || true
  if tmp=$(mktemp "$STATE/.fm-gbrain-audit.XXXXXX" 2>/dev/null); then
    if printf '%s\n' "$document" > "$tmp"; then
      mv -f "$tmp" "$path" || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi

  if [ "$json_mode" -eq 1 ]; then
    printf '%s\n' "$document"
  else
    printf '%s' "$document" | jq -r '
      "state      \(.state)",
      "stored     \(.stored) captured record(s)",
      "active     \(.active) page(s) the index serves for this home",
      "missing    \(.missing) captured record(s) the index no longer serves",
      "truncated  \(.truncated) stored bod(ies) cut at the capture cap",
      (.missing_slugs[] | "  missing  \(.)"),
      "detail     \(.detail)"'
  fi
  [ "$state" = ok ]
}

# --- the periodic sweep -----------------------------------------------------
#
# Gap 1 in one paragraph: capture fires at teardown, and a report edited after
# that never reaches capture again, so a page can serve a finding the captain
# later voided with nothing marking it stale. A rule that says "recapture after
# you edit a report" is a habit, and habits are exactly what this failed on.
# This is the structural version of that rule - an interval a session start arms
# unconditionally, so the worst case is one interval of staleness rather than
# forever. It reuses backfill for the refresh, because backfill already
# recomposes and re-delivers a changed body to the same page; a second
# recomposition path would be one more thing to drift.

FM_GBRAIN_CAPTURE_SWEEP_DEFAULT_INTERVAL=21600

sweep_marker_path() { printf '%s/.gbrain-capture-sweep\n' "$STATE"; }

sweep_due() {  # <interval-seconds>
  local marker mtime now
  marker=$(sweep_marker_path)
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || return 0
  now=$(date +%s)
  [ $((now - mtime)) -ge "$1" ]
}

cmd_sweep() {
  local seconds=$CAPTURE_TIMEOUT interval=${FM_GBRAIN_CAPTURE_SWEEP_INTERVAL:-$FM_GBRAIN_CAPTURE_SWEEP_DEFAULT_INTERVAL} force=0
  while [ $# -gt 0 ]; do
    case $1 in
      --timeout) seconds=${2:-}; shift 2 ;;
      --interval) interval=${2:-}; shift 2 ;;
      --force) force=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$seconds" in ''|*[!0-9]*|0) die "--timeout takes a positive number of seconds" ;; esac
  case "$interval" in ''|*[!0-9]*) interval=$FM_GBRAIN_CAPTURE_SWEEP_DEFAULT_INTERVAL ;; esac

  # Inert and silent in a home with no brain, exactly as `task` is: a fleet that
  # has not adopted GBrain must see no new output and no new files at all.
  brain_ready || return 0
  [ "$force" -eq 1 ] || sweep_due "$interval" || return 0

  local marker tmp said=0 rc=0
  marker=$(sweep_marker_path)
  mkdir -p "$STATE" 2>/dev/null || true
  # Stamped BEFORE the work, so a sweep killed part-way waits out its interval
  # rather than retrying on every session start. Nothing is lost by that:
  # backfill is restartable, and the next sweep recomposes whatever this one
  # did not reach.
  : > "$marker" 2>/dev/null || true

  tmp=$(mktemp) || return 0
  rc=0
  cmd_backfill --timeout "$seconds" > "$tmp" 2>/dev/null || rc=$?
  # Only the refreshed pages are reported. A sweep that captured a newly torn
  # down task, or re-read 300 unchanged ones, is routine and says nothing; a
  # page that was serving a stale body until this moment is the finding.
  if grep '^refreshed ' "$tmp" >/dev/null 2>&1; then
    grep '^refreshed ' "$tmp"
    said=1
  fi
  # A refusal is credential-shaped content in a durable report, which is a
  # finding about that report rather than routine sweep noise, and backfill
  # deliberately does not fail on it - so it would be silent here otherwise.
  if grep '^refused ' "$tmp" >/dev/null 2>&1; then
    grep '^refused ' "$tmp"
    said=1
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'the captured-knowledge refresh reported errors; run bin/fm-gbrain-capture.sh backfill by hand to see them\n'
    said=1
  fi

  rc=0
  cmd_audit --timeout "$seconds" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    awk '/^detail /{ sub(/^detail[[:space:]]+/, ""); print }' "$tmp"
    said=1
  fi
  rm -f "$tmp"
  [ "$said" -eq 0 ]
}

cmd_show() {
  local doc=${1:-}
  [ -n "$doc" ] || die "usage: fm-gbrain-capture.sh show <document-id>"
  fm_gbrain_capture_document_id_valid "$doc" || die "unsafe document id: $doc"
  local rc=0 item
  item=$(fm_gbrain_capture_item_read "$DATA" "$doc") || rc=$?
  case $rc in
    0) printf '%s\n' "$item" ;;
    2) die "the outbox record for $doc is unreadable or malformed" ;;
    *) die "no outbox record for $doc" ;;
  esac
}

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift
  case $cmd in
    task) cmd_task "$@" ;;
    note) cmd_note "$@" ;;
    process) cmd_process "$@" ;;
    backfill) cmd_backfill "$@" ;;
    audit) cmd_audit "$@" ;;
    sweep) cmd_sweep "$@" ;;
    status) cmd_status "$@" ;;
    show) cmd_show "$@" ;;
    -h | --help | help | '') usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
