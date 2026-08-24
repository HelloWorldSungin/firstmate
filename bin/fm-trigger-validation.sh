#!/usr/bin/env bash
# fm-trigger-validation.sh - firstmate owns the close line for the wait it ends.
#
# A no-mistakes ship worker parks with
#   blocked: implemented and committed, ready to validate
# and firstmate ends that wait by triggering validation. Firstmate therefore owns
# the `resolved:` line that closes it. Keeping the close at the trigger boundary
# makes the status fold reflect the decision without relying on worker bookkeeping.
#
# This script bundles the close line with the validation-trigger send. It follows
# bin/fm-captain-hold.sh's ownership pattern for a status transition firstmate
# completes.
#
# Usage:
#   fm-trigger-validation.sh <id> <message...>
#
#   <id>         the task id of the parked worker
#   <message...> the validation trigger to send, typically the harness no-mistakes
#                skill invocation (`/no-mistakes` or `$no-mistakes`); see the
#                `no-mistakes skill invocation` section of harness-adapters
#
# The send runs first: a confirmed delivery is the moment the wait ends, so the
# close line records that moment and is skipped on any delivery failure (firstmate
# retries or reconciles). The close line is then appended only when the worker's
# status fold actually has the exact default-keyed `blocked:` handoff a ship
# worker writes. A different default blocker is left open even after the send:
# the canonical handoff is firstmate-controlled, so a false negative is safer
# than clearing a blocker firstmate cannot positively identify. A design task
# parked on `paused:` opens no decision and is left untouched, and a keyed
# decision the worker still owes stays open, because a bare `resolved:` closes
# only the default key. This changes neither what `resolved:` means nor what the
# open-decision fold reconciles: the fold still drops the entry only on an
# explicit resolution, and firstmate now supplies that resolution for the one
# wait firstmate owns.
#
# firstmate-scoped: this is firstmate's own status-file record, so it is never run
# from a gate agent or a crewmate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The validation-trigger transport. Overridable so a test can stub the send
# without a real backend, the same way FM_CREW_STATE_BIN stubs the crew-state
# read; absent, it points at the real sibling script.
FM_SEND_BIN="${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# trigger validation on a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-trigger-validation refuses to operate without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi
ID=$1
shift
case "$ID" in
  ''|*[!A-Za-z0-9._-]*)
    echo "error: task id must be a privacy-safe slug: $ID" >&2
    exit 1
    ;;
esac

meta="$STATE/$ID.meta"
if [ ! -f "$meta" ]; then
  echo "error: no recorded task for id '$ID' (missing $meta)" >&2
  exit 1
fi
status_file="$STATE/$ID.status"

# Send the validation trigger first. fm-send resolves the task id to its endpoint,
# refuses an unresolved guess, and verifies the submit; its non-zero exit (a failed
# or unverifiable send) propagates here before any close line is written, so the
# block stays open exactly until the trigger is confirmed delivered.
"$FM_SEND_BIN" "$ID" "$@"

# Close the ready-to-validate block firstmate just ended. Match the complete
# canonical fold row, including its firstmate-controlled note, so a worker that
# replaces the default key with a genuine blocker during send settlement is left
# open. A non-match deliberately appends nothing: retaining a phantom handoff is
# safer than clearing a blocker firstmate cannot positively identify.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
open=$(status_open_decisions "$status_file")
canonical_handoff=$(printf 'default\tblocked\timplemented and committed, ready to validate')
if printf '%s\n' "$open" | grep -Fqx "$canonical_handoff"; then
  printf '%s\n%s\n' \
    'resolved: firstmate triggered validation, the ready-to-validate block is cleared' \
    'working: no-mistakes validation starting' >> "$status_file"
fi
