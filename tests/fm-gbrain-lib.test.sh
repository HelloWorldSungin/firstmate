#!/usr/bin/env bash
# Behavioral coverage for per-home GBrain scoping: brain isolation between
# homes, the closed shared-configuration schema, credential-mode refusal, the
# credential-free rendering of every generated artifact, what inheritance does
# and does not carry downstream, offline degradation, and retirement cleanup.
#
# The read/write asymmetry against a real brain cannot be proven without one, so
# it lives in tests/fm-gbrain-readonly-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-gbrain-lib)
CLI="$ROOT/bin/fm-gbrain.sh"

# Credential values the tests plant and then hunt for. Any generated artifact
# containing these bytes has leaked one.
CLIENT_SECRET='gbrain_cs_testonlytestonlytestonlytestonly0000'
MINIMAX_KEY='mm-testonly-key-0000'

SHARED_JSON='{
  "version": 1,
  "local": {
    "embedding_base_url": "http://127.0.0.1:11434/v1",
    "embedding_model": "ollama:snowflake-arctic-embed2:568m",
    "embedding_dimensions": 1024
  },
  "think": {
    "base_url": "https://api.minimax.io/v1",
    "model": "minimax:MiniMax-M3",
    "secret": "minimax-key"
  },
  "main_brain": {
    "mcp_url": "http://127.0.0.1:8787/mcp",
    "token_url": "http://127.0.0.1:8787/token",
    "mount": "fm-main",
    "scopes": "read",
    "secret": "main-brain-client-secret"
  }
}'

make_home() {  # <name> -> prints home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data"
  printf '%s\n' "$SHARED_JSON" > "$home/config/gbrain.json"
  printf '%s\n' "$home"
}

install_secret() {  # <home> <name> <value> [mode]
  local dir="$1/config/gbrain-secrets"
  mkdir -p "$dir"
  printf '%s\n' "$3" > "$dir/$2"
  chmod "${4:-600}" "$dir/$2"
}

# cli <home> <args...>: run the operator surface, capturing output and status.
# Sets CLI_OUT and CLI_RC rather than returning them, so a `set -u` caller can
# assert on both without a subshell.
cli() {
  local home=$1; shift
  CLI_RC=0
  CLI_OUT=$(FM_HOME="$home" FM_GBRAIN_TIMEOUT="${FM_GBRAIN_TIMEOUT:-2}" bash "$CLI" "$@" 2>&1) || CLI_RC=$?
}

pglite_of() {  # <home>
  cli "$1" paths --json
  printf '%s' "$CLI_OUT" | jq -r .pglite
}

# --- 1. each home resolves its OWN brain ------------------------------------

main_home=$(make_home main)
sm_home=$(make_home sm)

main_pglite=$(pglite_of "$main_home")
sm_pglite=$(pglite_of "$sm_home")

[ "$main_pglite" != "$sm_pglite" ] || fail "two homes resolved the same index at $main_pglite"
assert_contains "$main_pglite" "$main_home" "the main home's index must live under the main home"
assert_contains "$sm_pglite" "$sm_home" "a secondmate's index must live under that secondmate's home"
pass "each home derives its own brain from its own home path"

# The derivation must not depend on an operator remembering to configure it: a
# home with no brain configuration at all still resolves somewhere private.
bare_home="$TMP_ROOT/bare"
mkdir -p "$bare_home/config"
bare_pglite=$(pglite_of "$bare_home")
assert_contains "$bare_pglite" "$bare_home" "an unconfigured home must still resolve a private index"
pass "an unconfigured home resolves a private brain rather than a shared one"

# --- 1b. help describes the surface without spilling implementation ---------

cli "$main_home" --help
expect_code 0 "$CLI_RC" "--help must succeed"
assert_contains "$CLI_OUT" "grant-read" "--help must describe the commands"
assert_not_contains "$CLI_OUT" "set -euo pipefail" "--help must not print the script's code"
assert_not_contains "$CLI_OUT" "SCRIPT_DIR=" "--help must not print the script's code"
pass "the operator help renders the header and stops before the implementation"

# --- 2. the shared plane is a closed schema ---------------------------------
#
# This is what makes "the inherited file can neither point two homes at one
# brain nor carry a credential" a property rather than a naming convention.

refuse_shared() {  # <json> <expected-fragment> <label>
  local probe="$TMP_ROOT/probe"
  rm -rf "$probe"; mkdir -p "$probe/config"
  printf '%s\n' "$1" > "$probe/config/gbrain.json"
  cli "$probe" config
  expect_code 1 "$CLI_RC" "$3 must be refused"
  assert_contains "$CLI_OUT" "$2" "$3 must say why"
}

refuse_shared '{"version":1,"brain_root":"/tmp/shared"}' \
  'must not set "brain_root"' \
  'a brain location in the inherited file'
refuse_shared '{"version":1,"main_brain":{"client_id":"gbrain_cl_abc"}}' \
  'must not set "main_brain.client_id"' \
  'a client identity in the inherited file'
refuse_shared "{\"version\":1,\"main_brain\":{\"secret\":\"$CLIENT_SECRET\"}}" \
  'must NAME a file under config/gbrain-secrets/' \
  'a credential pasted into the inherited file'
refuse_shared '{"version":1,"local":{"embedding_endpoint":"http://127.0.0.1:1/v1"}}' \
  'unknown field' \
  'an unrecognized field'
refuse_shared '{"version":1,"main_brain":{"scopes":"write"}}' \
  'must be exactly "read"' \
  'a widened main-brain scope'
refuse_shared '{"version":1,"main_brain":{"scopes":"read write"}}' \
  'must be exactly "read"' \
  'a scope list that includes write'
refuse_shared '{"version":1,"main_brain":{"token_url":"http://brain.example.com/token"}}' \
  'plaintext http' \
  'a client secret sent to a non-loopback host in the clear'
pass "the inherited configuration refuses a brain location, a client identity, a credential, an unknown field, a widened scope, and a plaintext off-box endpoint"

remote_home="$TMP_ROOT/ok-remote"
mkdir -p "$remote_home/config"
printf '%s\n' '{"version":1,"main_brain":{"token_url":"https://brain.example.com/token","scopes":"read"}}' \
  > "$remote_home/config/gbrain.json"
cli "$remote_home" config
expect_code 0 "$CLI_RC" "an https main brain on another host must be accepted"
pass "a remote main brain is accepted over https"

# --- 3. credentials are refused unless stored restrictively -----------------

install_secret "$sm_home" main-brain-client-secret "$CLIENT_SECRET"
cli "$sm_home" check
assert_contains "$CLI_OUT" "mode 0600" "a correctly stored credential must be usable"

chmod 644 "$sm_home/config/gbrain-secrets/main-brain-client-secret"
cli "$sm_home" check
expect_code 1 "$CLI_RC" "a world-readable credential must fail the check"
assert_contains "$CLI_OUT" "must be a regular file with mode 0600" \
  "a loosely stored credential must be refused by name"
chmod 600 "$sm_home/config/gbrain-secrets/main-brain-client-secret"

mkdir -p "$sm_home/config/gbrain-secrets"
ln -sf /etc/hostname "$sm_home/config/gbrain-secrets/minimax-key"
cli "$sm_home" check
expect_code 1 "$CLI_RC" "a symlinked credential must fail the check"
assert_contains "$CLI_OUT" "must be a regular file" "a symlinked credential must be refused"
rm -f "$sm_home/config/gbrain-secrets/minimax-key"
install_secret "$sm_home" minimax-key "$MINIMAX_KEY"
pass "a credential is refused unless it is a regular file readable only by its owner"

# --- 4. no generated artifact carries credential bytes ----------------------
#
# The acceptance criterion is about bytes, so this greps the real output of
# every artifact-producing surface for the planted values.

artifacts="$TMP_ROOT/artifacts.txt"
{
  FM_HOME="$sm_home" FM_GBRAIN_TIMEOUT=2 bash "$CLI" config
  FM_HOME="$sm_home" FM_GBRAIN_TIMEOUT=2 bash "$CLI" config --json
  FM_HOME="$sm_home" FM_GBRAIN_TIMEOUT=2 bash "$CLI" paths
  FM_HOME="$sm_home" FM_GBRAIN_TIMEOUT=2 bash "$CLI" paths --json
  FM_HOME="$sm_home" FM_GBRAIN_TIMEOUT=2 bash "$CLI" env
  FM_HOME="$sm_home" FM_GBRAIN_TIMEOUT=2 bash "$CLI" check || true
  FM_HOME="$sm_home" FM_GBRAIN_TIMEOUT=2 bash "$CLI" check --json || true
} > "$artifacts" 2>&1

assert_no_grep "$CLIENT_SECRET" "$artifacts" \
  "a rendered artifact leaked the main-brain client secret"
assert_no_grep "$MINIMAX_KEY" "$artifacts" \
  "a rendered artifact leaked the MiniMax key"
assert_grep "main-brain-client-secret" "$artifacts" \
  "the rendered configuration should still name the credential it uses"
pass "no rendered configuration, path, environment, or check artifact contains credential bytes"

# The environment a gbrain call inherits must not carry a credential either:
# the MiniMax key is injected only into the one process that synthesizes.
cli "$sm_home" env
assert_not_contains "$CLI_OUT" "$MINIMAX_KEY" "the exported environment leaked the MiniMax key"
assert_not_contains "$CLI_OUT" "$CLIENT_SECRET" "the exported environment leaked the client secret"
assert_contains "$CLI_OUT" "GBRAIN_HOME=" "the exported environment must point gbrain at this home's brain"
pass "the environment handed to a gbrain call carries no credential"

# --- 5. inheritance carries the shared plane and nothing else ---------------

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"
items=$(fm_config_inherit_items)
assert_contains "$items" "config/gbrain.json" \
  "the shared brain configuration must propagate to secondmate homes"
assert_not_contains "$items" "gbrain-local.json" \
  "a home's own brain and client identity must never propagate"
assert_not_contains "$items" "gbrain-secrets" \
  "credentials must never propagate through inherited configuration"
pass "inheritance carries the shared brain configuration and neither identity nor credentials"

# Propagating the shared file verbatim must still leave the two homes writing
# different brains - the property the closed schema exists to guarantee.
cp "$main_home/config/gbrain.json" "$sm_home/config/gbrain.json"
[ "$(pglite_of "$main_home")" != "$(pglite_of "$sm_home")" ] \
  || fail "inheriting the shared configuration collapsed two homes onto one index"
pass "inheriting the shared configuration verbatim keeps each home on its own brain"

# --- 6. a home-local brain root stays home-local ----------------------------

jq -n --arg r "$TMP_ROOT/elsewhere" '{version:1, brain_root:$r}' \
  > "$main_home/config/gbrain-local.json"
cli "$main_home" paths --json
moved=$(printf '%s' "$CLI_OUT" | jq -r .brain_root)
[ "$moved" = "$TMP_ROOT/elsewhere" ] || fail "a home-local brain root override was not honored"
assert_contains "$(pglite_of "$sm_home")" "$sm_home" \
  "one home's brain root override must not move another home's brain"
pass "a home-local brain root moves only that home's brain"

jq -n --arg c "$CLIENT_SECRET" '{version:1, client_id:$c}' \
  > "$main_home/config/gbrain-local.json"
cli "$main_home" paths
expect_code 1 "$CLI_RC" "a client secret stored as a client id must be refused"
assert_contains "$CLI_OUT" "holds a client SECRET" "the refusal must name the mistake"
rm -f "$main_home/config/gbrain-local.json"
pass "a credential pasted into the home-local identity file is refused"

# --- 7. offline main brain and offline synthesis leave local search alone ---
#
# The shared configuration points at a main brain and a MiniMax endpoint that
# are not running here, which is exactly the offline case.

rm -f "$sm_home/config/gbrain-secrets/minimax-key"
cli "$sm_home" check --json
expect_code 0 "$CLI_RC" "an unreachable main brain and absent synthesis key must not fail the check"

state_of() { printf '%s' "$CLI_OUT" | jq -r --arg c "$1" '.[] | select(.check == $c) | .state'; }
[ "$(state_of main-brain)" = degraded ] \
  || fail "an unreachable main brain should read as degraded, got '$(state_of main-brain)'"
[ "$(state_of think)" = degraded ] \
  || fail "absent synthesis credentials should read as degraded, got '$(state_of think)'"
[ "$(state_of config)" = ok ] \
  || fail "the local plane should stay ok while remote services are down, got '$(state_of config)'"
assert_contains "$(printf '%s' "$CLI_OUT" | jq -r '.[] | select(.check == "main-brain") | .detail')" \
  "own search is unaffected" "the degraded report should say local retrieval still works"
pass "an offline main brain and unavailable synthesis degrade without breaking this home's local search"

# A credential that is present but unusable is a finding, not a degradation.
install_secret "$sm_home" minimax-key "$MINIMAX_KEY" 666
cli "$sm_home" check
expect_code 1 "$CLI_RC" \
  "a credential stored too loosely must fail the check even while remote services are down"
pass "a credential stored too loosely is a failure, not a degradation"

# --- 8. retirement refuses to destroy a brain without explicit approval -----

retire_home=$(make_home retiring)
mkdir -p "$retire_home/data/gbrain/pglite"
install_secret "$retire_home" main-brain-client-secret "$CLIENT_SECRET"

cli "$main_home" retire "$retire_home"
expect_code 1 "$CLI_RC" "retirement must refuse without explicit approval"
assert_contains "$CLI_OUT" "--yes" "the refusal must name what unlocks it"
assert_present "$retire_home/data/gbrain/pglite" "a refused retirement must leave the brain intact"

cli "$main_home" retire "$retire_home" --yes
expect_code 0 "$CLI_RC" "an approved retirement should succeed"
assert_absent "$retire_home/data/gbrain" "an approved retirement must remove that home's brain"
assert_absent "$retire_home/config/gbrain-secrets" "an approved retirement must remove that home's credentials"
pass "retirement destroys a home's brain and credentials only after explicit approval"

echo "all fm-gbrain-lib tests passed"
