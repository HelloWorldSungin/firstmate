#!/usr/bin/env bash
# tests/fm-cursor-agy-smoke.test.sh - live herdr smoke for the crew-only,
# herdr-only cursor/agy adapters. It launches each CLI through the EXACT
# bin/fm-launch-lib.sh template in an isolated Herdr lab pane and confirms herdr
# NATIVELY recognizes it, which is the load-bearing generic-detection claim that
# lets these adapters reuse herdr's liveness code and feed the watcher-side
# native-completion detector (verification data/cursor-agy-verify/report.md).
# For agy it also exercises the real
# workspace-trust seed/remove around the launch.
#
# Requires the explicit credentialed-test opt-in, then skips cleanly when any
# required binary or the supported Herdr event path is unavailable.
#
# Safety: ALL Herdr lifecycle goes through bin/fm-herdr-lab.sh on a private,
# named, throwaway session (never the default), which records the live default
# session before provisioning and verifies it identical after teardown. The
# adapter's own herdr calls (fm_backend_herdr_cli) append a trailing
# --session <lab> to every call, the same isolation the helper enforces.
set -u

if [ "${FM_CURSOR_AGY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CURSOR_AGY_LIVE_E2E=1 to run the cursor/agy live smoke"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/bin/fm-herdr-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

for t in herdr cursor-agent agy jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "skip: $t not found"; exit 0; }
done

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-launch-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agy-trust-lib.sh"
fm_backend_source herdr || { echo "skip: herdr backend could not be sourced"; exit 0; }
fm_backend_herdr_agent_prompt_version_check >/dev/null 2>&1 || { echo "skip: installed herdr lacks cursor/agy atomic prompt delivery"; exit 0; }

SESSION=$("$LAB" name cursor-agy-smoke) || { echo "skip: could not derive a lab session name"; exit 0; }
WORK=
AGY_TRUST_CREATED=0
FM_AGY_TRUST_ADDED=
cleanup() {
  if { [ "$AGY_TRUST_CREATED" = 1 ] || [ "${FM_AGY_TRUST_ADDED:-}" = created ]; } && [ -n "$WORK" ]; then
    if fm_agy_trust_remove "$WORK" >/dev/null 2>&1; then
      AGY_TRUST_CREATED=0
      FM_AGY_TRUST_ADDED=
    else
      printf 'not ok - agy workspace-trust cleanup for %s\n' "$WORK" >&2
    fi
  fi
  [ -z "$WORK" ] || rm -rf "$WORK"
  "$LAB" teardown "$SESSION" >/dev/null 2>&1 || printf 'not ok - lab teardown for %s\n' "$SESSION" >&2
}
trap cleanup EXIT
"$LAB" provision "$SESSION" >/dev/null 2>&1 || { echo "skip: could not provision the isolated Herdr lab session"; trap - EXIT; exit 0; }
export HERDR_SESSION="$SESSION"

WORK=$(mktemp -d)
printf 'Reply with exactly the single word PONG and nothing else.\n' > "$WORK/brief.md"

LAUNCH_TARGET=

# Launch <harness> through its fm_launch_template in a fresh lab pane and return
# 0 iff herdr's native `agent get` identifies it as <harness>. Sets LAUNCH_TARGET
# to the pane's "<session>:<pane>" on success, and waits for the crew to actually
# work and settle (a working -> idle/done transition on the delivered brief).
launch_and_detect() {  # <harness> <effort>
  local harness=$1 effort=$2 raw container seeded ses pane ids launch effortflag
  local brief_path opinput_path agent st saw_working=0 settled=0
  LAUNCH_TARGET=
  raw=$(fm_backend_herdr_container_ensure "$WORK") || { echo "container_ensure failed" >&2; return 1; }
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  ses=${container%%:*}
  ids=$(fm_backend_herdr_create_task "$container" "fm-smoke-$harness" "$WORK" "$seeded") \
    || { echo "create_task failed" >&2; return 1; }
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || { echo "no pane id" >&2; return 1; }
  effortflag=$(fm_launch_effort_flag "$harness" "$effort")
  launch=$(fm_launch_template "$harness") || { echo "no template" >&2; return 1; }
  brief_path=$(fm_launch_shell_quote "$WORK/brief.md")
  opinput_path=$(fm_launch_shell_quote "$ROOT/bin/fm-operational-input.sh")
  launch=$(fm_launch_render \
    "$launch" "" "$effortflag" "$brief_path" "" "" "" "" "$opinput_path") \
    || { echo "template render failed" >&2; return 1; }
  fm_backend_herdr_send_literal "$ses:$pane" "$launch" || { echo "send failed" >&2; return 1; }
  sleep 0.3
  fm_backend_herdr_send_key "$ses:$pane" Enter || { echo "enter failed" >&2; return 1; }
  agent=
  for _ in $(seq 1 40); do
    agent=$("$LAB" run "$SESSION" agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent // empty' 2>/dev/null)
    [ -z "$agent" ] || break
    sleep 1
  done
  [ "$agent" = "$harness" ] || { echo "native agent get reported '$agent', expected '$harness'" >&2; return 1; }
  [ "$(fm_backend_herdr_agent_alive "$ses:$pane")" = alive ] \
    || { echo "$harness pane not reported alive by the generic liveness probe" >&2; return 1; }
  # Observe a working->idle/done transition: the crew picks up the brief, works,
  # then settles (the exact edge the native completion detector keys on).
  for _ in $(seq 1 60); do
    st=$(fm_backend_agent_status herdr "$ses:$pane" 2>/dev/null)
    [ "$st" = working ] && saw_working=1
    case "$st" in idle|done) [ "$saw_working" = 1 ] && { settled=1; break; } ;; esac
    sleep 1
  done
  [ "$settled" = 1 ] || { echo "$harness never showed a working->idle/done transition on the brief" >&2; return 1; }
  LAUNCH_TARGET="$ses:$pane"
  return 0
}

# prove_completion_wake: reproduce the watcher's maybe_native_turnend decision
# against the REAL settled pane - read native agent_status, run it through the
# debounced fm_transition_native_completion, and confirm it produces the
# state/<id>.turn-ended completion signal that scan_signals turns into a wake.
prove_completion_wake() {  # <target> <harness>
  local target=$1 harness=$2 statedir tf prev="" newstate native_pair native_identity st signaled=0
  statedir=$(mktemp -d)
  tf="$statedir/task.turn-ended"
  fm_backend_herdr_parse_target "$target" || return 1
  for _ in $(seq 1 8); do
    native_pair=$(fm_backend_herdr_agent_identity_raw \
      "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" 2>/dev/null || true)
    native_identity=${native_pair%%$'\t'*}
    case "$native_pair" in
      *$'\t'*) st=${native_pair#*$'\t'} ;;
      *) st=unknown ;;
    esac
    if newstate=$(fm_transition_native_completion \
      "$harness" "$native_identity" "$st" "$prev"); then
      : > "$tf"
      signaled=1
    fi
    prev=$newstate
    [ "$signaled" = 1 ] && break
    sleep 1
  done
  if [ "$signaled" = 1 ] && [ -f "$tf" ]; then
    rm -rf "$statedir"
    return 0
  fi
  rm -rf "$statedir"
  return 1
}

# cursor: --trust --force, positional brief, effort encoded in the model string.
if launch_and_detect cursor default; then
  pass "cursor launches via its fm-spawn template, herdr natively detects it (alive), and it works then settles"
else
  fail "cursor did not launch, register, and settle as a native herdr agent"
fi
if prove_completion_wake "$LAUNCH_TARGET" cursor; then
  pass "cursor: the native debounced completion detector produces a turn-end wake from the settled pane"
else
  fail "cursor: no turn-end completion signal was produced from the settled native state"
fi

# agy: pre-seed exact-path workspace trust (as fm-spawn does), launch with
# --prompt-interactive + --effort, then remove the trust entry (as teardown does).
GLOBAL_SETTINGS="${HOME}/.gemini/antigravity-cli/settings.json"
fm_agy_trust_add "$WORK" || fail "agy workspace-trust seed failed"
[ "$FM_AGY_TRUST_ADDED" = created ] || fail "agy trust seed should report a created (firstmate-owned) entry"
AGY_TRUST_CREATED=1
jq -e --arg p "$WORK" '(.trustedWorkspaces // []) | index($p)' "$GLOBAL_SETTINGS" >/dev/null 2>&1 \
  || fail "agy workspace-trust seed did not record the exact worktree path"
if launch_and_detect agy high; then
  pass "agy launches via its fm-spawn template (trust pre-seeded), herdr natively detects it, and it works then settles"
else
  fail "agy did not launch, register, and settle as a native herdr agent"
fi
if prove_completion_wake "$LAUNCH_TARGET" agy; then
  pass "agy: the native debounced completion detector produces a turn-end wake from the settled pane"
else
  fail "agy: no turn-end completion signal was produced from the settled native state"
fi
fm_agy_trust_remove "$WORK" || fail "agy workspace-trust remove failed"
AGY_TRUST_CREATED=0
FM_AGY_TRUST_ADDED=
if jq -e --arg p "$WORK" '(.trustedWorkspaces // []) | index($p)' "$GLOBAL_SETTINGS" >/dev/null 2>&1; then
  fail "agy workspace-trust entry survived removal"
fi
pass "agy workspace trust is seeded before launch and removed afterward"

echo "# all fm-cursor-agy-smoke tests passed"
