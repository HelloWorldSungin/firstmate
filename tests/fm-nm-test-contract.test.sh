#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  local val
  if command -v ruby >/dev/null 2>&1; then
    val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    val=$(python3 - "$NM" <<'PY'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    doc = yaml.safe_load(stream) or {}
commands = doc.get("commands") or {}
value = commands.get("test") if isinstance(commands, dict) else None
print("" if value is None or value is False or value == "" else repr(value))
PY
) || fail "failed to parse .no-mistakes.yaml as YAML"
  else
    fail "Ruby YAML or Python PyYAML is required to parse .no-mistakes.yaml"
  fi
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command
printf '\nall fm-nm-test-contract tests passed\n'
