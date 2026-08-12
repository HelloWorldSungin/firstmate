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
    "base_url": "https://127.0.0.1:11435/v1",
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
refuse_shared '{"version":1,"main_brain":{"token_url":"http://[2001:db8::1]:8787/token"}}' \
  'non-loopback host [2001:db8::1]' \
  'a client secret sent to a non-loopback IPv6 host in the clear'
pass "the inherited configuration refuses a brain location, a client identity, a credential, an unknown field, a widened scope, and a plaintext off-box endpoint"

remote_home="$TMP_ROOT/ok-remote"
mkdir -p "$remote_home/config"
printf '%s\n' '{"version":1,"main_brain":{"token_url":"https://brain.example.com/token","scopes":"read"}}' \
  > "$remote_home/config/gbrain.json"
cli "$remote_home" config
expect_code 0 "$CLI_RC" "an https main brain on another host must be accepted"

# The loopback exemption is about the host, so it must survive the one syntax
# that hides a colon inside the authority.
v6_home="$TMP_ROOT/ok-v6"
mkdir -p "$v6_home/config"
printf '%s\n' '{"version":1,"main_brain":{"mcp_url":"http://[::1]:8787/mcp","token_url":"http://[::1]:8787/token","scopes":"read"}}' \
  > "$v6_home/config/gbrain.json"
cli "$v6_home" config
expect_code 0 "$CLI_RC" "a loopback IPv6 main brain must receive the loopback exemption"
pass "a remote main brain is accepted over https and a loopback IPv6 main brain over http"

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

# The link target is a real, correctly stored credential this test creates, so
# the refusal is about the redirection itself rather than about a missing file:
# [ -e ] follows the link, and a dangling one would read as absent instead.
mkdir -p "$sm_home/config/gbrain-secrets"
printf '%s\n' "$MINIMAX_KEY" > "$TMP_ROOT/linked-credential"
chmod 600 "$TMP_ROOT/linked-credential"
ln -sf "$TMP_ROOT/linked-credential" "$sm_home/config/gbrain-secrets/minimax-key"
cli "$sm_home" check
expect_code 1 "$CLI_RC" "a symlinked credential must fail the check"
assert_contains "$CLI_OUT" "must be a regular file" "a symlinked credential must be refused"
assert_not_contains "$CLI_OUT" "$MINIMAX_KEY" "a refused credential must not have been read"
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

# --- 5b. the schema is enforced where propagation happens -------------------
#
# The criterion is about bytes in generated artifacts, so this drives the real
# propagation and reread-instruction writers and then hunts the planted
# credential in what they actually produced.

prop_src="$TMP_ROOT/prop-src"
prop_dst="$TMP_ROOT/prop-dst"
mkdir -p "$prop_src/config" "$prop_dst/config" "$prop_dst/state"
prop_report="$TMP_ROOT/prop-report.tsv"
prop_instruction="$prop_dst/state/.fm-inherited-config-reread.probe"
prop_err="$TMP_ROOT/prop-error.txt"
prop_saved_items=$FM_INHERITABLE_CONFIG
FM_INHERITABLE_CONFIG="gbrain.json"
FM_CONFIG_INHERIT_REPORT="$prop_report"

# A valid shared plane really does propagate and really is inlined verbatim.
# Without this half the refusal below could pass for the wrong reason.
printf '%s\n' "$SHARED_JSON" > "$prop_src/config/gbrain.json"
: > "$prop_report"
propagate_inheritable_config "$prop_src/config" "$prop_dst/config" 2>/dev/null \
  || fail "a valid shared brain configuration must still propagate"
assert_present "$prop_dst/config/gbrain.json" "a valid shared plane must reach the secondmate home"
fm_config_write_reread_instruction "$prop_dst" "$prop_report" "$prop_instruction" \
  || fail "a pushed shared plane must produce a reread instruction"
assert_grep "main-brain-client-secret" "$prop_instruction" \
  "the reread instruction should carry the credential NAME that propagated"

# Now the exact mistake the closed schema exists to refuse: a live credential
# pasted where a credential name belongs.
printf '%s\n' "{\"version\":1,\"main_brain\":{\"secret\":\"$CLIENT_SECRET\"}}" \
  > "$prop_src/config/gbrain.json"
: > "$prop_report"
if propagate_inheritable_config "$prop_src/config" "$prop_dst/config" 2>"$prop_err"; then
  fail "propagating a credential-bearing shared plane returned success"
fi
assert_grep "must NAME a file under config/gbrain-secrets/" "$prop_err" \
  "the propagation refusal must name the mistake"
assert_no_grep "$CLIENT_SECRET" "$prop_dst/config/gbrain.json" \
  "a credential-bearing shared plane was copied into another home"
assert_grep "main-brain-client-secret" "$prop_dst/config/gbrain.json" \
  "the refusal must leave the last valid plane in place"
if fm_config_write_reread_instruction "$prop_dst" "$prop_report" "$prop_instruction"; then
  fail "a refused item must not produce a reread instruction"
fi

prop_artifacts="$TMP_ROOT/prop-artifacts.txt"
find "$prop_dst" -type f -exec cat {} + > "$prop_artifacts" 2>/dev/null
cat "$prop_err" >> "$prop_artifacts"
[ -s "$prop_artifacts" ] || fail "the artifact sweep found nothing to inspect"
assert_no_grep "$CLIENT_SECRET" "$prop_artifacts" \
  "an inheritance or reread artifact carries the credential pasted into the shared plane"

FM_INHERITABLE_CONFIG=$prop_saved_items
unset FM_CONFIG_INHERIT_REPORT
pass "a credential pasted into the inherited brain configuration is refused at the propagation boundary, before any home or reread artifact receives it"

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

state_of() { printf '%s' "$CLI_OUT" | jq -r --arg c "$1" '.[] | select(.check == $c) | .state'; }
detail_of() { printf '%s' "$CLI_OUT" | jq -r --arg c "$1" '.[] | select(.check == $c) | .detail'; }

# A home that was never granted a client has no outage to report, so the row
# must state that rather than blame the main brain for being unreachable.
rm -f "$sm_home/config/gbrain-secrets/minimax-key"
cli "$sm_home" check --json
expect_code 0 "$CLI_RC" "a home with no read-only client must not fail the check"
[ "$(state_of main-brain)" = absent ] \
  || fail "a home with no read-only client should read as absent, got '$(state_of main-brain)'"
assert_contains "$(detail_of main-brain)" "no read-only client" \
  "the row must say the client is missing rather than imply an outage"

jq -n '{version:1, client_id:"gbrain_cl_smtest"}' > "$sm_home/config/gbrain-local.json"
cli "$sm_home" check --json
expect_code 0 "$CLI_RC" "an unreachable main brain and absent synthesis key must not fail the check"
[ "$(state_of main-brain)" = degraded ] \
  || fail "an unreachable main brain should read as degraded, got '$(state_of main-brain)'"
[ "$(state_of think)" = degraded ] \
  || fail "absent synthesis credentials should read as degraded, got '$(state_of think)'"
[ "$(state_of config)" = ok ] \
  || fail "the local plane should stay ok while remote services are down, got '$(state_of config)'"
assert_contains "$(detail_of main-brain)" \
  "own search is unaffected" "the degraded report should say local retrieval still works"
pass "an offline main brain and unavailable synthesis degrade without breaking this home's local search"

# A readable key proves nothing about the endpoint, so the row must be the
# answer the endpoint gave rather than an inference from the credential.
install_secret "$sm_home" minimax-key "$MINIMAX_KEY"
cli "$sm_home" check --json
expect_code 0 "$CLI_RC" "an unreachable synthesis endpoint must not fail the check"
[ "$(state_of think)" = degraded ] \
  || fail "an unreachable synthesis endpoint should read as degraded even with a usable key, got '$(state_of think)'"
assert_contains "$(detail_of think)" "no answer at" \
  "the row must report the endpoint that did not answer, not the key that was readable"
pass "a usable synthesis key with an unreachable endpoint still reads as degraded"
rm -f "$sm_home/config/gbrain-secrets/minimax-key"

# A credential that is present but unusable is a finding, not a degradation.
install_secret "$sm_home" minimax-key "$MINIMAX_KEY" 666
cli "$sm_home" check
expect_code 1 "$CLI_RC" \
  "a credential stored too loosely must fail the check even while remote services are down"
pass "a credential stored too loosely is a failure, not a degradation"

# --- 8. retirement destroys only what it created, and only on approval ------

retire_home=$(make_home retiring)
mkdir -p "$retire_home/data/gbrain/pglite" "$retire_home/data/gbrain/runtime"
install_secret "$retire_home" main-brain-client-secret "$CLIENT_SECRET"

cli "$main_home" retire "$retire_home"
expect_code 1 "$CLI_RC" "retirement must refuse without explicit approval"
assert_contains "$CLI_OUT" "--yes" "the refusal must name what unlocks it"
assert_present "$retire_home/data/gbrain/pglite" "a refused retirement must leave the brain intact"

cli "$main_home" retire "$retire_home" --yes
expect_code 0 "$CLI_RC" "an approved retirement should succeed"
assert_absent "$retire_home/data/gbrain/pglite" "an approved retirement must remove that home's index"
assert_absent "$retire_home/data/gbrain/runtime" "an approved retirement must remove that home's runtime"
assert_absent "$retire_home/config/gbrain-secrets" "an approved retirement must remove that home's credentials"
pass "retirement destroys a home's brain and credentials only after explicit approval"

# A brain_root override may name a GBrain deployment this tool never created, so
# retirement removes the children it derives and nothing that surrounds them.
external="$TMP_ROOT/external-deployment"
mkdir -p "$external/pglite" "$external/runtime" "$external/archive" "$external/unrelated"
printf 'not ours\n' > "$external/unrelated/keep.txt"
printf 'not ours\n' > "$external/deployment.json"
ext_home=$(make_home retiring-external)
jq -n --arg r "$external" '{version:1, brain_root:$r}' > "$ext_home/config/gbrain-local.json"

cli "$main_home" retire "$ext_home"
expect_code 1 "$CLI_RC" "retirement must still refuse without --yes"
assert_contains "$CLI_OUT" "leave the brain root $external" \
  "the preview must say the operator-supplied root itself survives"

cli "$main_home" retire "$ext_home" --yes
expect_code 0 "$CLI_RC" "retiring a home with an external brain root should succeed"
assert_absent "$external/pglite" "retirement must remove the index it derives"
assert_absent "$external/runtime" "retirement must remove the runtime it derives"
assert_absent "$external/archive" "retirement must remove the archive it derives"
assert_present "$external" "retirement must not remove an operator-supplied brain root"
assert_present "$external/unrelated/keep.txt" "retirement must not remove anything it did not create"
assert_present "$external/deployment.json" "retirement must not remove anything it did not create"
pass "retirement removes the brain directories it derives and never the operator-supplied root"

# --- 9. the operator surface against a stand-in gbrain ----------------------
#
# The read/write asymmetry needs a real brain and lives in the e2e suite. What
# is portable here is whether this surface reports only what it established:
# what it writes, what it preserves, and what it refuses to call done.

export FAKE_CLIENT_ID=gbrain_cl_fake0001
export FAKE_CLIENT_SECRET=gbrain_cs_fakefakefakefakefakefake0001
cat > "$TMP_ROOT/fake-gbrain" <<'SH'
#!/usr/bin/env bash
# Enough of the gbrain CLI to drive registration and revocation where a real
# brain is not available. Setting a FAILS variable to "lock" mimics the
# single-writer refusal; any other value is emitted as the raw failure text, so
# a test can tell a recognized failure shape from an unrecognized one.
fake_gbrain_refuse() {  # <mode>
  case $1 in
    lock) echo "brain already open through .gbrain-lock" ;;
    *) echo "$1" ;;
  esac
  exit 1
}
case "${1:-} ${2:-}" in
  "auth register-client")
    [ -z "${FAKE_GBRAIN_REGISTER_FAILS:-}" ] || fake_gbrain_refuse "$FAKE_GBRAIN_REGISTER_FAILS"
    echo "Client ID: ${FAKE_CLIENT_ID:?}"
    echo "Client Secret: ${FAKE_CLIENT_SECRET:?}"
    ;;
  "auth revoke-client")
    [ -z "${FAKE_GBRAIN_REVOKE_FAILS:-}" ] || fake_gbrain_refuse "$FAKE_GBRAIN_REVOKE_FAILS"
    echo "revoked ${3:-}"
    ;;
  *) echo "unexpected gbrain call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$TMP_ROOT/fake-gbrain"
export FM_GBRAIN_BIN="$TMP_ROOT/fake-gbrain"

# A target whose home-local plane cannot be read is refused before anything is
# registered, and that file is left exactly as it was.
bad_target=$(make_home grant-bad)
printf '%s\n' '{"version":1,"brain_root":"/tmp/keep-me",}' > "$bad_target/config/gbrain-local.json"
bad_before=$(cat "$bad_target/config/gbrain-local.json")
cli "$main_home" grant-read fm-bad --home "$bad_target"
expect_code 1 "$CLI_RC" "granting into an unreadable home-local plane must be refused"
assert_contains "$CLI_OUT" "not valid JSON" "the refusal must name the mistake"
[ "$(cat "$bad_target/config/gbrain-local.json")" = "$bad_before" ] \
  || fail "a refused grant rewrote the target's home-local plane"
assert_absent "$bad_target/config/gbrain-secrets/main-brain-client-secret" \
  "a refused grant must not install a credential"
pass "a grant into a home whose local plane cannot be read changes nothing"

# A registration the brain refused establishes nothing, so the granting home
# must not come away claiming to be the main brain. The claim is sticky and
# `check` reports it confidently, so a refused grant that left one behind would
# be worse than no claim at all.
refused_owner=$(make_home grant-refused)
refused_target=$(make_home grant-refused-target)
export FAKE_GBRAIN_REGISTER_FAILS=lock
cli "$refused_owner" grant-read fm-refused --home "$refused_target"
unset FAKE_GBRAIN_REGISTER_FAILS
expect_code 1 "$CLI_RC" "a registration the main brain refused must fail the grant"
assert_contains "$CLI_OUT" "being served" "the refusal must name the single-writer cause"
assert_absent "$refused_owner/config/gbrain-local.json" \
  "a refused grant recorded an ownership claim it never established"
assert_absent "$refused_target/config/gbrain-secrets/main-brain-client-secret" \
  "a refused grant installed a credential"
cli "$refused_owner" check --json
expect_code 0 "$CLI_RC" "a home whose grant was refused must still check cleanly"
[ "$(state_of main-brain)" = absent ] \
  || fail "a home whose grant was refused must not report owning the main brain, got '$(state_of main-brain)'"
pass "a refused registration leaves the granting home's local plane exactly as it found it"

good_target=$(make_home grant-good)
jq -n --arg r "$TMP_ROOT/grant-good-brain" '{version:1, brain_root:$r}' \
  > "$good_target/config/gbrain-local.json"
cli "$main_home" grant-read fm-good --home "$good_target"
expect_code 0 "$CLI_RC" "granting read-only access should succeed"
assert_not_contains "$CLI_OUT" "$FAKE_CLIENT_SECRET" "grant-read printed the credential it installed"
[ "$(jq -r .client_id "$good_target/config/gbrain-local.json")" = "$FAKE_CLIENT_ID" ] \
  || fail "grant-read did not record the client id in the target home"
[ "$(jq -r .brain_root "$good_target/config/gbrain-local.json")" = "$TMP_ROOT/grant-good-brain" ] \
  || fail "grant-read dropped the target home's own brain root"
granted_secret="$good_target/config/gbrain-secrets/main-brain-client-secret"
granted_mode=$(stat -c %a "$granted_secret" 2>/dev/null || stat -f %Lp "$granted_secret")
[ "$granted_mode" = 600 ] || fail "the installed credential has mode $granted_mode, expected 600"
pass "grant-read installs the identity and the credential without printing it or dropping the target's own configuration"

# The home that just registered a client on its own brain IS the main brain, so
# its own check reports reading it directly rather than a missing credential.
[ "$(jq -r .main_brain_owner "$main_home/config/gbrain-local.json")" = true ] \
  || fail "granting did not record the granting home as the main brain's owner"
cli "$main_home" check --json
expect_code 0 "$CLI_RC" "the owning home's check must succeed"
[ "$(state_of main-brain)" = ok ] \
  || fail "the owning home should not report its own main brain as unreachable, got '$(state_of main-brain)'"
assert_contains "$(detail_of main-brain)" "owns the main brain" \
  "the owning home's row must say it reads its own index directly"
pass "the home that owns the main brain reports reading it directly rather than minting a token to itself"

# A retirement that cannot revoke is not a retirement.
revoke_home=$(make_home retiring-live)
mkdir -p "$revoke_home/data/gbrain/pglite"
install_secret "$revoke_home" main-brain-client-secret "$CLIENT_SECRET"
jq -n --arg c "$FAKE_CLIENT_ID" '{version:1, client_id:$c}' \
  > "$revoke_home/config/gbrain-local.json"

export FAKE_GBRAIN_REVOKE_FAILS=lock
cli "$main_home" retire "$revoke_home" --yes
unset FAKE_GBRAIN_REVOKE_FAILS
expect_code 1 "$CLI_RC" "a retirement that cannot revoke must not report success"
assert_contains "$CLI_OUT" "being served" "the refusal must say what has to happen first"
assert_present "$revoke_home/data/gbrain/pglite" "a failed revocation must leave the brain intact"
assert_present "$revoke_home/config/gbrain-secrets/main-brain-client-secret" \
  "a failed revocation must leave the credential record intact for the retry"
assert_present "$revoke_home/config/gbrain-local.json" \
  "a failed revocation must leave the record of which client to revoke"

# A failure shape with no friendlier phrasing must still reach the operator: a
# blocking refusal that does not say why cannot be acted on.
cause_home=$(make_home retiring-cause)
mkdir -p "$cause_home/data/gbrain/pglite"
install_secret "$cause_home" main-brain-client-secret "$CLIENT_SECRET"
jq -n --arg c "$FAKE_CLIENT_ID" '{version:1, client_id:$c}' \
  > "$cause_home/config/gbrain-local.json"

export FAKE_GBRAIN_REVOKE_FAILS='no such client gbrain_cl_fake0001'
cli "$main_home" retire "$cause_home" --yes
unset FAKE_GBRAIN_REVOKE_FAILS
expect_code 1 "$CLI_RC" "an unrecognized revocation failure must still stop the retirement"
assert_contains "$CLI_OUT" "no such client gbrain_cl_fake0001" \
  "the refusal must carry the cause gbrain reported"
assert_present "$cause_home/data/gbrain/pglite" \
  "a refused retirement must leave the brain intact whatever the cause"

export FAKE_GBRAIN_REVOKE_FAILS='the auth store is unreadable'
cli "$main_home" revoke-read "$FAKE_CLIENT_ID"
unset FAKE_GBRAIN_REVOKE_FAILS
expect_code 1 "$CLI_RC" "a failed revoke-read must fail"
assert_contains "$CLI_OUT" "the auth store is unreadable" \
  "revoke-read must carry the cause gbrain reported too"

cli "$main_home" retire "$revoke_home" --yes
expect_code 0 "$CLI_RC" "the retry after a successful revocation should complete"
assert_contains "$CLI_OUT" "revoked $FAKE_CLIENT_ID" "a completed retirement must report the revocation"
assert_absent "$revoke_home/data/gbrain/pglite" "a completed retirement must remove that home's index"
assert_absent "$revoke_home/config/gbrain-secrets" "a completed retirement must remove that home's credentials"
pass "a retirement whose revocation fails removes nothing, says why in gbrain's own words, and can be retried"

# An ambient FM_CONFIG_OVERRIDE addresses the ACTIVE home. A command that names
# another home must still resolve that home's own directory, or it would write a
# credential to, or delete one from, a home the operator never named.
override_config="$TMP_ROOT/override-config"
mkdir -p "$override_config"
printf '%s\n' "$SHARED_JSON" > "$override_config/gbrain.json"
override_target=$(make_home grant-override)

export FM_CONFIG_OVERRIDE="$override_config"
cli "$main_home" grant-read fm-override --home "$override_target"
unset FM_CONFIG_OVERRIDE
expect_code 0 "$CLI_RC" "granting under an active-home config override should succeed"
assert_present "$override_target/config/gbrain-secrets/main-brain-client-secret" \
  "the credential must land in the home the command named"
assert_absent "$override_config/gbrain-secrets" \
  "an override of the active home must not redirect another home's credential"
[ "$(jq -r .client_id "$override_target/config/gbrain-local.json")" = "$FAKE_CLIENT_ID" ] \
  || fail "the client id must be recorded in the home the command named"

install_secret "$override_target" main-brain-client-secret "$CLIENT_SECRET"
mkdir -p "$override_config/gbrain-secrets"
printf 'active-home credential\n' > "$override_config/gbrain-secrets/main-brain-client-secret"
chmod 600 "$override_config/gbrain-secrets/main-brain-client-secret"
mkdir -p "$override_target/data/gbrain/pglite"

export FM_CONFIG_OVERRIDE="$override_config"
cli "$main_home" retire "$override_target" --yes
unset FM_CONFIG_OVERRIDE
expect_code 0 "$CLI_RC" "retiring under an active-home config override should succeed"
assert_absent "$override_target/config/gbrain-secrets" \
  "retirement must remove the credentials of the home it named"
assert_absent "$override_target/data/gbrain/pglite" \
  "retirement must remove the index of the home it named"
assert_present "$override_config/gbrain-secrets/main-brain-client-secret" \
  "retirement must never remove the active home's own credentials"
pass "a command that names a home acts on that home, whatever config directory the active home is using"

# --- 10. the serving-credential rule is checked, not only stated ------------
#
# docs/gbrain.md forbids a home from serving its brain while holding a usable
# hosted synthesis credential, because since GBrain v0.42.76.0 a read-only
# holder reaches think on the serving home. The verdict keys off the actual
# serving relationship (main_brain_owner) and the actual credential plane
# (think.secret present), so the cases below pin each input independently.
# Fail by: dropping the serving-with-credential branch, keying off a home name,
# treating an unreadable plane as clean, or removing the grant-read warning.

# A home that holds the credential but serves no brain is a latent case: clean,
# because the boundary is not live yet. Keys off the serving relationship rather
# than the credential alone, so a check that flagged any credential-holder would
# fail here.
latent_home=$(make_home serving-latent)
install_secret "$latent_home" minimax-key "$MINIMAX_KEY"
cli "$latent_home" check --json
expect_code 0 "$CLI_RC" "a home that holds a credential but serves no brain must pass"
[ "$(state_of serving-credential)" = ok ] \
  || fail "a non-serving home should read serving-credential as ok, got '$(state_of serving-credential)'"
cli "$latent_home" serving-check
expect_code 0 "$CLI_RC" "serving-check must never exit non-zero; the line is the signal"
[ -z "$CLI_OUT" ] || fail "serving-check must stay silent on a clean home, got: $CLI_OUT"
pass "a credential-holding home that serves no brain is clean (the latent case)"

# Mark that same home as the main brain owner and the forbidden configuration
# exists: check must fail the serving-credential row and exit non-zero, and
# serving-check must announce it. Fail by: removing the violation branch, or by
# the check no longer treating the violation as a hard failure.
printf '%s\n' '{"version":1,"main_brain_owner":true}' > "$latent_home/config/gbrain-local.json"
cli "$latent_home" check --json
expect_code 1 "$CLI_RC" "a serving home holding a usable hosted synthesis credential must fail the check"
[ "$(state_of serving-credential)" = failed ] \
  || fail "a serving credential-holder should read serving-credential as failed, got '$(state_of serving-credential)'"
assert_contains "$(detail_of serving-credential)" "minimax-key" \
  "the violation must name the credential by its plane name"
assert_not_contains "$(detail_of serving-credential)" "$MINIMAX_KEY" \
  "the violation must not leak the credential bytes"
cli "$latent_home" serving-check
expect_code 0 "$CLI_RC" "serving-check never exits non-zero; the line is the signal"
assert_contains "$CLI_OUT" "GBRAIN_SERVING_CREDENTIAL:" "serving-check must announce the violation"
assert_contains "$CLI_OUT" "serves its brain" "the alarm must say the home is serving"
assert_not_contains "$CLI_OUT" "$MINIMAX_KEY" "the serving-check alarm must not leak the credential bytes"
pass "a serving home that holds a usable hosted synthesis credential fails the check and raises the alarm"

# Removing the credential clears the violation, pinning the credential plane as
# a required input rather than serving alone. Fail by: flagging any serving home.
rm -f "$latent_home/config/gbrain-secrets/minimax-key"
cli "$latent_home" check --json
expect_code 0 "$CLI_RC" "a serving home with no usable hosted synthesis credential must pass"
[ "$(state_of serving-credential)" = ok ] \
  || fail "a serving home with the credential removed should read ok, got '$(state_of serving-credential)'"
pass "the violation clears once the credential is gone, so serving alone is not enough"

# A present credential this process refuses to read leaves the credential plane
# unknown rather than proving it absent. Fail by: collapsing refused credentials
# into the same clean state as a genuinely missing credential.
install_secret "$latent_home" minimax-key "$MINIMAX_KEY" 644
cli "$latent_home" check --json
[ "$(state_of serving-credential)" = unknown ] \
  || fail "a refused credential plane should read serving-credential as unknown, got '$(state_of serving-credential)'"
cli "$latent_home" serving-check
assert_contains "$CLI_OUT" "GBRAIN_SERVING_CREDENTIAL:" \
  "serving-check must raise an unreadable credential plane rather than pass silently"
assert_contains "$CLI_OUT" "mode 0600" \
  "the unknown diagnostic must say why the credential plane could not be read"
pass "a refused credential plane is unknown, never a silent pass"

# A home whose serving relationship cannot be read is unknown, never a pass: an
# unreadable plane must not look like a check that ran and found nothing. Fail
# by: defaulting an unreadable plane to ok (which would silence serving-check).
unknown_home=$(make_home serving-unknown)
install_secret "$unknown_home" minimax-key "$MINIMAX_KEY"
printf '%s\n' '{"version":1,"main_brain_owner":' > "$unknown_home/config/gbrain-local.json"
cli "$unknown_home" check --json
[ "$(state_of serving-credential)" = unknown ] \
  || fail "an unreadable local plane should read serving-credential as unknown, got '$(state_of serving-credential)'"
cli "$unknown_home" serving-check
assert_contains "$CLI_OUT" "GBRAIN_SERVING_CREDENTIAL:" \
  "serving-check must raise unknown rather than pass silently"
pass "an unreadable serving relationship is unknown, never a silent pass"

# grant-read warns at the moment the forbidden configuration is created:
# registering the first reading client is the ordinary action that turns a latent
# credential into a live boundary, so the warning must fire then and must not
# leak the credential. Fail by: removing the grant-read warning.
warn_owner=$(make_home serving-warn-owner)
install_secret "$warn_owner" minimax-key "$MINIMAX_KEY"
warn_target=$(make_home serving-warn-target)
cli "$warn_owner" grant-read fm-warn --home "$warn_target"
expect_code 1 "$CLI_RC" "a grant that creates the forbidden configuration returns a warning, not success"
assert_contains "$CLI_OUT" "SERVES its brain" "grant-read must warn that the home now serves"
assert_contains "$CLI_OUT" "hosted synthesis credential" "the warning must name what makes it a boundary"
assert_not_contains "$CLI_OUT" "$MINIMAX_KEY" "the grant warning must not leak the credential bytes"
[ "$(jq -r .main_brain_owner "$warn_owner/config/gbrain-local.json")" = true ] \
  || fail "the granting home must still be recorded as the main brain owner"
pass "grant-read warns the moment a serving home's credential becomes a live boundary"

echo "all fm-gbrain-lib tests passed"
