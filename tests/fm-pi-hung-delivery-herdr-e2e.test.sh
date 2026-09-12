#!/usr/bin/env bash
# Opt-in real Pi/Herdr regression for later-cycle restore while branch
# settlement is hung. Every Herdr call is routed through fm-herdr-lab.sh.
# The named lab is never default. Isolated FM_HOME. Abort before any provider
# call. The portable suite pins the same restore/delivery split without Pi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

if [ "${FM_PI_HUNG_DELIVERY_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_HUNG_DELIVERY_HERDR_E2E=1 to run the isolated Pi hung-settlement Herdr regression"
  exit 0
fi

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

herdr_forget_inherited_pane

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-pi-hung-deliv)
TMP_ROOT=$(fm_test_tmproot fm-pi-hung-delivery-herdr-e2e)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
HANG_EXT="$TMP_ROOT/hang-dispatch.ts"
LAUNCH="$TMP_ROOT/launch-pi.sh"
PANE=
UNATTENDED_SECS=8

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$PANE" ]; then
    "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" '/quit' >/dev/null 2>&1 || true
    sleep 1
  fi
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

"$LAB_HELPER" provision "$SESSION"

mkdir -p "$HOME_DIR"/{state,config,data} "$PROJECT" "$PI_DIR"
printf '# Synthetic isolated hung-settlement lab\n' > "$PROJECT/AGENTS.md"

cat > "$HANG_EXT" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.events?.on?.("fm-branch-supervision:dispatch", (data: { accept?: (p: Promise<void>) => void }) => {
    data.accept?.(new Promise(() => {}));
  });
  pi.on("before_agent_start", (_event, ctx) => {
    ctx.abort();
  });
}
EOF

wait_markers() {
  local i=0
  while [ "$i" -lt 120 ]; do
    if [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ]; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

cycle_count() { # <needle>
  local needle=$1 file=$HOME_DIR/state/.watch-cycle-exits.log count=0
  if [ -f "$file" ]; then
    count=$(grep -cE "$needle" "$file" || true)
  fi
  printf '%s\n' "${count:-0}"
}

wait_started() { # <need>
  local need=$1 i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cycle_count 'successor=started:')" -ge "$need" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

beacon_age_s() {
  local beat=$HOME_DIR/state/.last-watcher-beat now mtime
  [ -f "$beat" ] || return 1
  now=$(date +%s)
  mtime=$(stat -c %Y "$beat")
  printf '%s\n' "$((now - mtime))"
}

OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label fm-pi-hung-deliv --no-focus) \
  || fail "Herdr lab workspace create failed"
PANE=$(printf '%s' "$OUT" | jq -er '.result.root_pane.pane_id') \
  || fail "Herdr lab workspace create omitted pane id"

cat > "$LAUNCH" <<EOF
#!/usr/bin/env bash
set -u
echo \$\$ > $(printf %q "$HOME_DIR/state/.lock")
exec env \\
  FM_HOME=$(printf %q "$HOME_DIR") \\
  FM_ROOT_OVERRIDE=$(printf %q "$ROOT") \\
  PI_CODING_AGENT_DIR=$(printf %q "$PI_DIR") \\
  FM_POLL=1 \\
  FM_SIGNAL_GRACE=0 \\
  FM_HEARTBEAT=600 \\
  FM_CHECK_INTERVAL=999999 \\
  pi --approve --no-session --no-context-files --no-extensions \\
    -e $(printf %q "$HANG_EXT") \\
    -e $(printf %q "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts") \\
    -e $(printf %q "$ROOT/.pi/extensions/fm-primary-pi-watch.ts") \\
    --model openai-codex/gpt-5.6-sol --thinking low
EOF
chmod +x "$LAUNCH"

"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$LAUNCH" >/dev/null \
  || fail "could not launch isolated Pi in the named Herdr lab"

wait_markers || fail "Pi watch and turn-end extensions did not load in the isolated lab"

cat > "$HOME_DIR/state/hung-cycle.meta" <<EOF
window=$SESSION:synthetic-worker
backend=herdr
kind=ship
mode=direct-PR
worktree=$PROJECT
project=synthetic-hung-settlement
EOF

printf 'done: simulated hung completion 1\n' >> "$HOME_DIR/state/hung-cycle.status"
wait_started 1 || fail "first actionable close did not start a successor while settlement hung"

printf 'done: simulated hung completion 2\n' >> "$HOME_DIR/state/hung-cycle.status"
wait_started 2 || fail "second actionable close did not restore a successor while settlement hung"

printf 'done: simulated hung completion 3\n' >> "$HOME_DIR/state/hung-cycle.status"
wait_started 3 || fail "third actionable close did not restore a successor while settlement hung"

none=$(cycle_count 'successor=none')
[ "$none" -eq 0 ] || fail "hung settlement left successor=none after later-cycle restores (none=$none)"

sleep "$UNATTENDED_SECS"
age=$(beacon_age_s) || fail "watcher beacon missing after the unattended interval"
[ "$age" -le $((UNATTENDED_SECS + 5)) ] || fail "watcher beacon went stale during the unattended interval (age=${age}s)"
[ "$(cycle_count 'successor=started:')" -ge 3 ] || fail "unattended interval lost restored successors"
[ "$(cycle_count 'successor=none')" -eq 0 ] || fail "unattended interval recorded successor=none"

printf 'ok - isolated Pi hung-settlement Herdr lab restored later-cycle successors and kept a fresh beacon\n'
printf '\nall fm-pi-hung-delivery-herdr-e2e tests passed\n'
