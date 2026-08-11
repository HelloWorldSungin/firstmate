#!/usr/bin/env bash
# Behavior regression for bin/fm-pointer-check.sh - the cross-system pointer
# resolver.
#
# The case this suite exists for is the third verdict. A private repository
# answers an unauthenticated request with 404, byte-identically to a repository
# whose owner never existed, so a checker with only ok/broken must call one of
# those two wrong. Every test below drives the script through a stub GitHub API
# rather than the network, so the portable suite is offline and deterministic,
# and asserts the verdict SPLIT rather than only that some verdict was printed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pointer-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pointer-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# A stub `gh` that answers `gh api -i <endpoint>` from a routing table, in the
# real client's shape: the status line goes to stdout even for an error, and the
# process exit code is nonzero. FM_GH_MODE picks the credential posture.
#
#   authenticated  a token that can see HelloWorldSungin/* and users/torvalds
#   anonymous      no credential at all (real gh exits 4 with empty stdout)
#   ratelimited    a usable credential whose pointer lookups then come back 403
write_stub_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Stub GitHub client: gh api -i <endpoint>
endpoint=""
for arg in "$@"; do
  case "$arg" in
    api|-i) ;;
    *) endpoint=$arg ;;
  esac
done

emit() {
  printf 'HTTP/2.0 %s\n' "$1"
  printf 'Content-Type: application/json\n\n'
  printf '{}\n'
  [ "${1%% *}" -lt 400 ] && exit 0
  printf 'gh: %s\n' "$1" >&2
  exit 1
}

case "${FM_GH_MODE:-authenticated}" in
  anonymous)
    printf 'To get started with GitHub CLI, please run:  gh auth login\n' >&2
    exit 4
    ;;
  ratelimited)
    # The credential itself works; the pointer lookups are what get throttled.
    [ "$endpoint" = "user" ] && emit "200 OK"
    emit "403 Forbidden"
    ;;
esac

case "$endpoint" in
  user) emit "200 OK" ;;
  # An owner that exists. Account existence is public, so the stub answers
  # these the same way GitHub does regardless of what is private below them.
  users/HelloWorldSungin|users/torvalds) emit "200 OK" ;;
  users/*) emit "404 Not Found" ;;
  # A private repository this credential CAN see.
  repos/HelloWorldSungin/ArkNode-AI) emit "200 OK" ;;
  repos/HelloWorldSungin/firstmate) emit "200 OK" ;;
  # An owner that exists with a repository this credential CANNOT see.
  repos/torvalds/*) emit "404 Not Found" ;;
  repos/*/*/contents/docs/design/2026-08-10-ct110-sealed-corpus.md*) emit "200 OK" ;;
  repos/*/*/contents/*) emit "404 Not Found" ;;
  repos/*/*/issues/76) emit "200 OK" ;;
  repos/*/*/issues/*) emit "404 Not Found" ;;
  repos/*) emit "404 Not Found" ;;
  *) emit "404 Not Found" ;;
esac
SH
  chmod +x "$fakebin/gh"
}

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
write_stub_gh "$FAKEBIN"
export FM_POINTER_CHECK_GH="$FAKEBIN/gh"

# The five pointer shapes the conversions produce, in one prose surface.
write_pointer_fixture() {
  cat > "$TMP_ROOT/pointers.md" <<'MD'
# Pointers

Correct pointer into a private repository:
[record](https://github.com/HelloWorldSungin/ArkNode-AI/blob/master/docs/design/2026-08-10-ct110-sealed-corpus.md)

Owner account that does not exist:
[wrong owner](https://github.com/HelloWorldSungin-nope-9f3a/ArkNode-AI/blob/master/docs/design/2026-08-10-ct110-sealed-corpus.md)

Owner exists, repository not visible to this credential:
[invisible](https://github.com/torvalds/some-private-thing/blob/master/README.md)

Visible repository, path that is not in it:
[missing path](https://github.com/HelloWorldSungin/firstmate/blob/main/docs/absent.md)

Visible repository, issue that exists:
[the issue](https://github.com/HelloWorldSungin/firstmate/issues/76)

Visible repository, issue that does not exist:
[missing issue](https://github.com/HelloWorldSungin/firstmate/issues/999999)
MD
}

test_authenticated_verdicts_split_three_ways() {
  write_pointer_fixture
  local out rc
  set +e
  out=$(FM_GH_MODE=authenticated "$CHECK" --verbose "$TMP_ROOT/pointers.md" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a broken pointer must fail the run"

  assert_contains "$out" "2026-08-10-ct110-sealed-corpus.md  path-resolved" \
    "the private-repository blob path this credential can see must resolve to the file"
  assert_contains "$out" "owner-not-found" \
    "an owner account that does not exist is the one definitive broken case"
  assert_contains "$out" "repo-not-visible" \
    "an invisible repository must name why it could not be resolved"
  assert_contains "$out" "ref-or-path-not-found" \
    "a missing path inside a VISIBLE repository is broken, not unverified"
  assert_contains "$out" "issue-not-found" "a missing issue in a visible repository is broken"
  assert_contains "$out" "checked=6 ok=2 broken=3 unverified=1 skipped=0" \
    "the summary must account for every pointer by verdict"
  pass "authenticated resolution separates ok, broken, and could-not-verify"
}

test_unauthenticated_never_reads_404_as_a_verdict() {
  write_pointer_fixture
  local out rc
  set +e
  out=$(FM_GH_MODE=anonymous "$CHECK" --verbose "$TMP_ROOT/pointers.md" 2>&1)
  rc=$?
  set -e

  # The trap: without a credential the correct pointer and the broken one are
  # indistinguishable, so neither may be given a verdict.
  expect_code 0 "$rc" "unverified pointers must not fail the run"
  assert_contains "$out" "checked=6 ok=0 broken=0 unverified=6 skipped=0" \
    "with no credential every remote pointer must be unverified"
  assert_contains "$out" "credential=none" "the summary must disclose that nothing was checked"
  assert_contains "$out" "no-credential" "each unverified pointer must name the missing credential"
  assert_not_contains "$out" "broken     " \
    "an unauthenticated 404 must never be reported as a broken pointer"
  assert_not_contains "$out" "ok         " \
    "an unauthenticated 404 must never be reported as a working pointer"
  pass "no credential yields could-not-verify, never a broken or working verdict"
}

test_require_credential_refuses_a_vacuous_pass() {
  write_pointer_fixture
  local out rc
  set +e
  out=$(FM_GH_MODE=anonymous "$CHECK" --require-credential "$TMP_ROOT/pointers.md" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "--require-credential must refuse to pass having verified nothing"
  assert_contains "$out" "no usable GitHub credential" "the refusal must name the missing credential"

  set +e
  out=$(FM_GH_MODE=authenticated "$CHECK" --require-credential "$TMP_ROOT/ok-only.md" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a missing file is a usage error, not a pointer verdict"
  assert_contains "$out" "no such file or directory" "a missing input must be reported as such"
  pass "--require-credential turns a credential-less run into an explicit refusal"
}

test_rate_limit_is_unverified_not_broken() {
  cat > "$TMP_ROOT/one.md" <<'MD'
[record](https://github.com/HelloWorldSungin/firstmate/issues/76)
MD
  local out rc
  set +e
  out=$(FM_GH_MODE=ratelimited "$CHECK" --verbose "$TMP_ROOT/one.md" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a throttled lookup must not fail the run"
  assert_contains "$out" "unverified" "a 403 answer resolves nothing"
  assert_contains "$out" "broken=0" "a throttled lookup is not evidence the pointer is broken"
  assert_contains "$out" "rate-limited-or-forbidden" "the throttled lookup must name why it resolved nothing"
  pass "a throttled or forbidden lookup is could-not-verify, never broken"
}

test_examples_and_foreign_hosts_are_not_pointers() {
  cat > "$TMP_ROOT/examples.md" <<'MD'
# Examples

A fenced illustration of the wire format, not a pointer:

```sh
gh pr view https://github.com/o/r/pull/1
```

A verification record quoting a deliberately broken pointer inside a fence,
in link syntax, which must also stay out of the pointer surface:

```console
$ check [wrong owner](https://github.com/HelloWorldSungin-nope-9f3a/x/blob/main/a.md)
broken     owner-not-found
```

An inline one too: `https://github.com/acme/widget/issues/19`.

A template: https://github.com/<owner>/<repo>/issues/1

A real pointer on another host: [spec](https://www.w3.org/TR/trace-context/)

A real GitHub pointer: [issue](https://github.com/HelloWorldSungin/firstmate/issues/76)
MD
  local out rc
  set +e
  out=$(FM_GH_MODE=authenticated "$CHECK" --verbose "$TMP_ROOT/examples.md" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "illustrations must not fail the run"
  assert_not_contains "$out" "github.com/o/r/pull/1" \
    "a URL inside a code fence is an illustration, not a pointer"
  assert_not_contains "$out" "HelloWorldSungin-nope-9f3a" \
    "link syntax inside a fence is still an example - a verification record must be able to quote a broken pointer"
  assert_not_contains "$out" "github.com/acme/widget" \
    "a URL inside an inline code span is an illustration, not a pointer"
  assert_not_contains "$out" "<owner>" "a template URL has no target to resolve"
  assert_contains "$out" "w3.org/TR/trace-context/  no-adapter" \
    "a host with no resolver must be skipped explicitly, not silently"
  assert_contains "$out" "checked=2 ok=1 broken=0 unverified=0 skipped=1" \
    "only the two real pointers may be counted"
  pass "fenced, inline, and templated URLs are excluded from the pointer surface"
}

test_code_comment_pointers_resolve() {
  # A pointer does not have to live in Markdown. This is the code-to-prose
  # shape: a comment in a source file naming the record that owns the fact.
  cat > "$TMP_ROOT/inbox.js" <<'JS'
// The policy this module executes is owned at
// https://github.com/HelloWorldSungin/firstmate/issues/76 and restated nowhere.
export const POLICY = {};
JS
  local out rc
  set +e
  out=$(FM_GH_MODE=authenticated "$CHECK" --verbose "$TMP_ROOT/inbox.js" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a resolvable comment pointer must pass"
  assert_contains "$out" "issue-resolved" "a pointer in a code comment must resolve like any other"
  pass "pointers in code comments are resolved, not only Markdown links"
}

test_json_output_carries_every_verdict() {
  write_pointer_fixture
  local out
  set +e
  out=$(FM_GH_MODE=authenticated "$CHECK" --json "$TMP_ROOT/pointers.md" 2>&1)
  set -e
  printf '%s' "$out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["credential"] == "authenticated", data["credential"]
assert data["counts"] == {"ok": 2, "broken": 3, "unverified": 1, "skipped": 0}, data["counts"]
verdicts = {p["verdict"] for p in data["pointers"]}
assert verdicts == {"ok", "broken", "unverified"}, verdicts
for pointer in data["pointers"]:
    assert pointer["reason"], pointer
' || fail "JSON output did not carry each pointer with its verdict and reason"
  pass "JSON output reports every pointer, verdict, and reason"
}

test_default_scan_selects_tracked_prose() {
  # With no paths the check scans this repository's tracked Markdown. Verdicts
  # here come from the stub, so only the SELECTION is asserted; whether the real
  # targets resolve is a live question CI answers by running the check itself.
  local out
  set +e
  out=$(FM_GH_MODE=authenticated "$CHECK" --json 2>&1)
  set -e
  printf '%s' "$out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["files"] > 10, data["files"]
assert data["pointers"], "the default scan found no pointer in tracked prose"
sources = {p["source"] for p in data["pointers"]}
assert not any(s.startswith("/") for s in sources), sources
' || fail "the default scan did not select this repository's tracked prose"
  pass "the default scan selects tracked Markdown and reports repo-relative sources"
}

test_authenticated_verdicts_split_three_ways
test_unauthenticated_never_reads_404_as_a_verdict
test_require_credential_refuses_a_vacuous_pass
test_rate_limit_is_unverified_not_broken
test_examples_and_foreign_hosts_are_not_pointers
test_code_comment_pointers_resolve
test_json_output_carries_every_verdict
test_default_scan_selects_tracked_prose
