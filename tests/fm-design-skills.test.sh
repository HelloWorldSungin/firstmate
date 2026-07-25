#!/usr/bin/env bash
# Contract tests for the vendored Matt Pocock design toolkit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

skills="
ask-matt
grilling
grill-me
batch-grill-me
to-questionnaire
handoff
to-spec
domain-modeling
prototype
"

for skill in $skills; do
  file="$ROOT/.agents/skills/$skill/SKILL.md"
  assert_present "$file" "vendored design skill is absent: $skill"
  assert_grep "source: https://github.com/mattpocock/skills" "$file" \
    "$skill lost its source attribution"
  assert_grep "license: MIT" "$file" "$skill lost its MIT license attribution"
  assert_grep "Copyright (c) 2026 Matt Pocock" "$file" \
    "$skill lost its copyright attribution"
  assert_no_grep "disable-model-invocation:" "$file" \
    "$skill still carries a model-invocation lock"
done

for excluded in grill-with-docs to-tickets implement triage; do
  assert_absent "$ROOT/.agents/skills/$excluded" \
    "excluded marketplace flow was vendored into the design namespace: $excluded"
done

assert_present "$ROOT/docs/licenses/mattpocock-skills-MIT.txt" \
  "vendored toolkit is missing the complete MIT license"
assert_grep "Copyright (c) 2026 Matt Pocock" \
  "$ROOT/docs/licenses/mattpocock-skills-MIT.txt" \
  "complete license lost the required copyright"
assert_grep "\`batch-grill-me\` is unlocked but forbidden inside \`kind=design\`" \
  "$ROOT/.agents/skills/ask-matt/SKILL.md" \
  "router did not preserve sequential design interviews"
assert_grep "Do not invoke or recreate \`to-tickets\` or \`implement\`" \
  "$ROOT/.agents/skills/ask-matt/SKILL.md" \
  "router did not preserve Firstmate task and ship ownership"
assert_grep "records \`kind=scout\` plus \`profile=prototype\`" \
  "$ROOT/.agents/skills/prototype/SKILL.md" \
  "prototype was not wired as a scout-shaped detour"

pass "vendored Matt Pocock design skills are attributed, model-invocable, and bounded to Firstmate lifecycle ownership"
