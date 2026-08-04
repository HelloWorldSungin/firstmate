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
#             Restartable: each item is durable and independent, so a run that
#             stops halfway loses nothing and a rerun resumes.
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
# PGLite index, would keep a lifecycle-critical path parked forever. This
# mirrors run_timed in bin/fm-teardown.sh, which bounds the other call on that
# same path.
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
  # The brain this home writes is its OWN, resolved through the per-home
  # configuration: GBRAIN_HOME picks the index, and the embedding endpoint is
  # passed per call because GBrain does not persist a command-scoped one.
  out=$(
    export GBRAIN_HOME="$BRAIN_HOME_DIR"
    [ -n "$BRAIN_EMBED_URL" ] && export OLLAMA_BASE_URL="$BRAIN_EMBED_URL"
    run_bounded "$seconds" "$GBRAIN_BIN" capture \
      --file "$body" --slug "$slug" --type "$type" --json 2>&1
  ) || rc=$?
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

  local scanned=0 enqueued=0 captured=0 already=0 refused=0 errors=0 n=0
  local dir id raw title doc_id rc item
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
    # Already captured at this exact content version: a rerun re-delivers
    # nothing, which is what makes the whole sweep cheap to restart.
    if [ "$(printf '%s' "$item" | jq -r '.status // ""')" = captured ]; then
      already=$((already + 1))
      continue
    fi
    if process_item "$doc_id" "$seconds" 0 >/dev/null; then
      captured=$((captured + 1))
    else
      errors=$((errors + 1))
    fi
    item=$(fm_gbrain_capture_item_read "$DATA" "$doc_id") || item='{}'
    write_receipt "$id" \
      "$(printf '%s' "$item" | jq -r '.status // "pending"')" \
      "$(printf '%s' "$item" | jq -r '.gbrain_document // .slug // ""')" \
      "$(printf '%s' "$item" | jq -r '(.revision_id // "") + (if .last_error then "; " + .last_error else "" end)')" || true
  done
  printf 'backfill scanned=%d enqueued=%d captured=%d already-captured=%d refused=%d errors=%d\n' \
    "$scanned" "$enqueued" "$captured" "$already" "$refused" "$errors"
  [ "$errors" -eq 0 ]
}

# The outbox holds one record per completed task and grows with the fleet's
# history, so the listing is built in ONE jq pass over every file rather than by
# re-serializing an accumulator per record. A record jq cannot read is projected
# as "unreadable" instead of dropped, because a listing that silently omits a
# damaged record reads as "nothing to do".
cmd_status() {
  local json_mode=0 docs id item
  [ "${1:-}" = --json ] && json_mode=1
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
  if [ "$json_mode" -eq 1 ]; then
    printf '%s' "$docs" | jq '{
      schema: "fm-gbrain-capture-status.v1",
      totals: {
        archived: (map(select(.status == "captured")) | length),
        pending: (map(select(.status == "pending")) | length),
        failed: (map(select(.status == "failed")) | length),
        unreadable: (map(select(.status == "unreadable")) | length),
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
    "redacted   \(map(.redactions // [] | map(.count) | add // 0) | add // 0) value(s)",
    (.[] | "  \(.status)\t\(.document_id)\t\((.redactions // []) | map("\(.class)x\(.count)") | join(",") // "")\(if .last_error then "\t" + .last_error else "" end)")
  '
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
    status) cmd_status "$@" ;;
    show) cmd_show "$@" ;;
    -h | --help | help | '') usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
