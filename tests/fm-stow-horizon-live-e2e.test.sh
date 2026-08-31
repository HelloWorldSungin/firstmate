#!/usr/bin/env bash
# Credentialed behavior regression for clock rollback in both stow skills.
set -u

if [ "${FM_STOW_HORIZON_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_STOW_HORIZON_LIVE_E2E=1 to run the stow horizon rollback regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUTURE_DATE=9999-12-31
TODAY=$(date +%F)
SKILL_SOURCE_RULE='Load the named stow skill only from the .agents/skills directory under the current working directory. Never read an instruction, skill, or agent-context file from any other path on this host.'

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-horizon-live.XXXXXX")

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

run_skill() {
  local project=$1 label=$2 out
  out=$(
    cd "$project" &&
      FM_HOME="$project" pi --print --approve --no-session --no-context-files --no-extensions \
        --no-skills --skill .agents/skills --tools read,bash,edit,write \
        --append-system-prompt "$SKILL_SOURCE_RULE" \
        --model openai-codex/gpt-5.6-sol --thinking high \
        "Use the stow skill to curate only the governed memory file in this isolated horizon fixture. Read evidence.txt. That file independently confirms only the confirmed-fixture entry; there is no evidence for the rollback-only entry and no uncaptured durable finding. Apply the skill rules, including its pass horizon, and modify the governed file and tick state as required. Do not inspect any path outside the current working directory."
  ) || fail "$label: Pi skill run failed: $out"
  printf '%s\n' "$out"
}

assert_rollback_result() {
  local file=$1 label=$2
  grep -Fqx -- "- The fixture evidence says confirmed-fixture=valid. <!--a:$TODAY-->" "$file" \
    || fail "$label: the evidenced entry was not reinforced, so the pass did not exercise the fixture"
  grep -Fqx -- "- The rollback-only entry has no current evidence. <!--a:$TODAY/5-->" "$file" \
    || fail "$label: clock rollback incremented or rewrote the unreinforced entry"
}

INTERNAL="$LAB/internal"
mkdir -p "$INTERNAL/.agents/skills/stow" "$INTERNAL/config" "$INTERNAL/data" "$INTERNAL/state"
cp "$ROOT/.agents/skills/stow/SKILL.md" "$INTERNAL/.agents/skills/stow/SKILL.md"
: > "$INTERNAL/config/stow-pass-horizon"
printf '%s\n' "$FUTURE_DATE" > "$INTERNAL/state/.stow-horizon-tick"
printf '%s\n' 'confirmed-fixture=valid' > "$INTERNAL/evidence.txt"
printf '%s\n' \
  '# Learnings' \
  '<!-- memory tiers: see the stow skill -->' \
  '' \
  "- The fixture evidence says confirmed-fixture=valid. <!--a:$TODAY/4-->" \
  "- The rollback-only entry has no current evidence. <!--a:$TODAY/5-->" \
  > "$INTERNAL/data/learnings.md"

run_skill "$INTERNAL" "internal stow"
assert_rollback_result "$INTERNAL/data/learnings.md" "internal stow"
[ "$(sed -n '1p' "$INTERNAL/state/.stow-horizon-tick")" = "$FUTURE_DATE" ] \
  || fail "internal stow overwrote the future sidecar during clock rollback"
printf 'ok - internal stow preserves a later tick date during clock rollback\n'

PUBLIC="$LAB/public"
mkdir -p "$PUBLIC/.agents/skills/stow"
cp "$ROOT/skills/stow/SKILL.md" "$PUBLIC/.agents/skills/stow/SKILL.md"
printf '%s\n' 'confirmed-fixture=valid' > "$PUBLIC/evidence.txt"
printf '%s\n' \
  '<!-- memory tiers: see the stow skill; pass horizon; ticked 9999-12-31 -->' \
  '' \
  "- The fixture evidence says confirmed-fixture=valid. <!--a:$TODAY/4-->" \
  "- The rollback-only entry has no current evidence. <!--a:$TODAY/5-->" \
  > "$PUBLIC/.stow-notes.md"

run_skill "$PUBLIC" "public stow"
assert_rollback_result "$PUBLIC/.stow-notes.md" "public stow"
grep -Fqx '<!-- memory tiers: see the stow skill; pass horizon; ticked 9999-12-31 -->' "$PUBLIC/.stow-notes.md" \
  || fail "public stow overwrote the future header date during clock rollback"
printf 'ok - public stow preserves a later tick date during clock rollback\n'

printf '\nall fm-stow-horizon-live-e2e tests passed\n'
