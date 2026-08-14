#!/usr/bin/env bash
# Behavior tests for bin/fm-tool-status.sh, the read-only toolchain staleness
# report.
#
# The suite is hermetic: it never touches the network. The pure subcommands
# (version-gte, latest-ga, release-ga, floors) are tested directly, and the
# full report is driven end to end against a fakebin PATH where every tool,
# npm, gh-axi, curl, and jq are stubs that record their own invocations.
#
# Beyond correctness of the version logic (pre-release-vs-GA is the hard-learned
# rule: no-mistakes ships pre-releases above its GA), the report test asserts
# the read-only contract behaviorally: npm is only ever invoked with `view`,
# gh-axi only with `release list`, and no stub ever sees `install`, `update`,
# or `setup hooks`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-tool-status.sh"

TMP=$(fm_test_tmproot fm-tool-status)

# --- version-gte -------------------------------------------------------------

vcmp() { # vcmp <expected-rc> <a> <b> <label>
  local expected=$1 rc
  "$TOOL" version-gte "$2" "$3" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "version-gte: $4 (rc=$rc, want $expected)"
pass "version-gte: $4"
}

vcmp 0 0.1.30 0.1.29 "newer patch is gte"
vcmp 1 0.1.29 0.1.30 "older patch is not gte"
vcmp 0 0.1.30 0.1.30 "equal is gte"
vcmp 1 0.1.9 0.1.10 "numeric compare, not lexicographic"
vcmp 1 1.9 1.10 "numeric compare across depths"
vcmp 0 0.45.14.0 0.45.9.0 "four-segment gbrain-style versions"
vcmp 0 2.1.0 2.1 "missing segment counts as zero"
vcmp 0 v1.48.0 1.48.0 "leading v is ignored"
if "$TOOL" version-gte "v1.41.2 (867d64d)" "1.41.2" >/dev/null 2>&1; then
  pass "version-gte: build suffix ignored"
else
  fail "version-gte: build suffix ignored"
fi
rc=0
"$TOOL" version-gte "garbage" "1.0.0" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "version-gte: unparseable input must exit 2 (rc=$rc)"
pass "version-gte: unparseable input refused, not assumed"

# --- latest-ga (string-shaped pre-release filtering) --------------------------

out=$("$TOOL" latest-ga 2.1.0 2.1.1)
[ "$out" = "2.1.1" ] || fail "latest-ga: plain versions pick highest (got '$out')"
pass "latest-ga: plain versions pick highest"
out=$("$TOOL" latest-ga 1.51.0-rc1 1.48.0)
[ "$out" = "1.48.0" ] || fail "latest-ga: hyphenated pre-release excluded (got '$out')"
pass "latest-ga: hyphenated pre-release excluded"
out=$("$TOOL" latest-ga 2.0.0-beta3 2.0.0-alpha1 1.9.9)
[ "$out" = "1.9.9" ] || fail "latest-ga: beta and alpha markers excluded (got '$out')"
pass "latest-ga: beta and alpha markers excluded"
out=$("$TOOL" latest-ga preview-2026-08-04 0.8.0)
[ "$out" = "0.8.0" ] || fail "latest-ga: preview tag excluded (got '$out')"
pass "latest-ga: preview tag excluded"
out=$("$TOOL" latest-ga 2.0.0-rc.1 2>&1)
[ -z "$out" ] || fail "latest-ga: all-pre-release input must print nothing (got '$out')"
pass "latest-ga: all-pre-release input prints nothing"
"$TOOL" latest-ga 2.0.0-rc.1 >/dev/null 2>&1
[ "$?" -eq 1 ] || fail "latest-ga: no GA candidate must exit non-zero"
pass "latest-ga: no GA candidate exits non-zero"

# --- release-ga (flag-based pre-release filtering from gh-axi rows) -----------

# Captured gh-axi release list shape: the no-mistakes case from 2026-08-14,
# where three pre-releases sit above the GA and the highest number is NOT the
# latest release.
NM_ROWS='count: 6 (showing first 6)
releases[6]{tag,name,draft,prerelease,published}:
  v1.51.0,v1.51.0,no,yes,17h ago
  v1.50.0,v1.50.0,no,yes,2d ago
  v1.49.0,v1.49.0,no,yes,3d ago
  v1.48.0,v1.48.0,no,no,6d ago
  v1.47.0,v1.47.0,no,yes,7d ago
  v1.46.0,v1.46.0,no,no,8d ago'
out=$(printf '%s\n' "$NM_ROWS" | "$TOOL" release-ga)
printf '%s\n' "$out" | grep -q '^ga=v1.48.0$' || fail "release-ga: GA must be v1.48.0, got: $out"
pass "release-ga: pre-releases above GA excluded"
printf '%s\n' "$out" | grep -q '^pre=v1.51.0$' || fail "release-ga: pre must be v1.51.0, got: $out"
pass "release-ga: newest pre-release reported for the note"

# Drafts are never GA candidates even when unflagged as pre-release.
DRAFT_ROWS='releases[2]{tag,name,draft,prerelease,published}:
  v1.52.0,v1.52.0,yes,no,1h ago
  v1.48.0,v1.48.0,no,no,6d ago'
out=$(printf '%s\n' "$DRAFT_ROWS" | "$TOOL" release-ga)
printf '%s\n' "$out" | grep -q '^ga=v1.48.0$' || fail "release-ga: draft row must be skipped, got: $out"
pass "release-ga: draft row skipped"

# herdr's shape: dated preview builds not flagged pre-release by GitHub; the
# tag shape itself must catch them.
HERDR_ROWS='releases[2]{tag,name,draft,prerelease,published}:
  preview-2026-08-04,Preview Build,no,no,1d ago
  0.8.0,v0.8.0,no,no,2w ago'
out=$(printf '%s\n' "$HERDR_ROWS" | "$TOOL" release-ga)
printf '%s\n' "$out" | grep -q '^ga=0.8.0$' || fail "release-ga: GA must be 0.8.0, got: $out"
pass "release-ga: unflagged preview tag caught by shape"
printf '%s\n' "$out" | grep -q '^pre=preview-2026-08-04$' || fail "release-ga: pre must be preview-2026-08-04, got: $out"
pass "release-ga: preview named in pre"

# No GA row at all: refuse rather than guess.
ONLY_PRE='releases[1]{tag,name,draft,prerelease,published}:
  v2.0.0-rc1,v2.0.0-rc1,no,yes,1h ago'
out=$(printf '%s\n' "$ONLY_PRE" | "$TOOL" release-ga)
printf '%s\n' "$out" | grep -q '^ga=none$' || fail "release-ga: ga must be none, got: $out"
pass "release-ga: no GA row reports none"

# --- floors (live read from the three floor-owning files) ---------------------

FLOORS=$("$TOOL" floors)

floor_row() { # floor_row <tool> <source-file-basename> <label>
  printf '%s\n' "$FLOORS" | grep -E "^$1 +[A-Z_]+ +[0-9][0-9.]* +.*/bin/$2$" >/dev/null \
    || fail "floors: $3; got: $(printf '%s\n' "$FLOORS" | grep "^$1 " || true)"
pass "floors: $3"
}
floor_row gh-axi fm-bootstrap.sh "GH_AXI_MIN read from bootstrap"
floor_row lavish-axi fm-bootstrap.sh "LAVISH_AXI_MIN read from bootstrap"
floor_row no-mistakes fm-bootstrap.sh "NO_MISTAKES_MIN read from bootstrap"
floor_row tasks-axi fm-tasks-axi-lib.sh "FM_TASKS_AXI_MIN read from its lib"
floor_row quota-axi fm-quota-axi-lib.sh "FM_QUOTA_AXI_MIN read from its lib"
printf '%s\n' "$FLOORS" | grep -E '^chrome-devtools-axi +none +- +no floor by design$' >/dev/null \
  || fail "floors: chrome-devtools-axi must show no floor by design"
pass "floors: chrome-devtools-axi reported floorless by design"
if printf '%s\n' "$FLOORS" | grep -E 'unreadable' >/dev/null; then
  fail "floors: every declared floor must resolve"
fi
pass "floors: every declared floor resolves"
# Floor values are read live, so assert shape, not today's numbers; the repo's
# own floor files are the fixture.
while read -r tool var; do
  live=$(printf '%s\n' "$FLOORS" | awk -v t="$tool" -v v="$var" '$1 == t && $2 == v { print $3; exit }')
  src=$(awk -v v="$var" '$0 ~ "^" v "=" { sub("^" v "=", ""); print; exit }' "$ROOT/bin/fm-bootstrap.sh")
  [ "$live" = "$src" ] || fail "floors: $var drifted from bootstrap ($live vs $src)"
  pass "floors: $var matches its owning file"
done <<'EOF'
gh-axi GH_AXI_MIN
lavish-axi LAVISH_AXI_MIN
no-mistakes NO_MISTAKES_MIN
EOF

# --- full report against a stubbed world --------------------------------------

FAKEBIN=$(fm_fakebin "$TMP")
LOG="$FAKEBIN/invocations.log"
: >"$LOG"

mk_stub() { # mk_stub <name> <body...>
  local name=$1
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$*"
  } >"$FAKEBIN/$name"
  chmod +x "$FAKEBIN/$name"
}

# Stub npm: read-only `view` only; every call is recorded so the suite can
# prove the report never installs, updates, or runs setup hooks.
cat >"$FAKEBIN/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >>"$(dirname "$0")/invocations.log"
[ "${1:-}" = view ] || { printf 'npm stub: refused non-view call\n' >&2; exit 64; }
case ${2:-} in
  gh-axi) printf '0.1.30\n' ;;
  chrome-devtools-axi) printf '0.1.29\n' ;;
  lavish-axi) printf '0.1.50\n' ;;
  tasks-axi) printf '0.2.5\n' ;;
  quota-axi) printf '0.1.28\n' ;;
  gnhf) exit 1 ;;
  @earendil-works/pi-coding-agent) printf '0.84.2\n' ;;
  *) printf 'npm stub: unknown package\n' >&2; exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/npm"

# Stub gh-axi: read-only `release list` only, with the captured row format.
cat >"$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >>"$(dirname "$0")/invocations.log"
if [ "${1:-}" = --version ]; then printf '0.1.30\n'; exit 0; fi
[ "${1:-}" = release ] && [ "${2:-}" = list ] || exit 64
repo=
while [ $# -gt 0 ]; do
  if [ "$1" = --repo ]; then repo=$2; fi
  shift
done
case $repo in
  kunchenguid/no-mistakes)
    printf 'count: 4\n  v1.51.0,v1.51.0,no,yes,17h ago\n  v1.50.0,v1.50.0,no,yes,2d ago\n  v1.49.0,v1.49.0,no,yes,3d ago\n  v1.48.0,v1.48.0,no,no,6d ago\n'
    ;;
  kunchenguid/treehouse)
    printf 'count: 1\n  v2.1.1,v2.1.1,no,no,2w ago\n'
    ;;
  garrytan/gbrain)
    printf 'count: 1\n  v0.45.14.0,v0.45.14.0,no,no,1d ago\n'
    ;;
  herdrdev/herdr)
    printf 'count: 2\n  preview-2026-08-04,Preview,no,no,1d ago\n  0.8.0,v0.8.0,no,no,2w ago\n'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

# Stub curl and jq for herdr's latest.json read.
cat >"$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$(dirname "$0")/invocations.log"
printf '{"version":"0.8.0","notes":"stub"}\n'
SH
chmod +x "$FAKEBIN/curl"
cat >"$FAKEBIN/jq" <<'SH'
#!/usr/bin/env bash
input=$(cat)
pat='"version"[[:space:]]*:[[:space:]]*"([^"]+)"'
[[ $input =~ $pat ]] && printf '%s\n' "${BASH_REMATCH[1]}"
SH
chmod +x "$FAKEBIN/jq"

# Installed versions: one stub per fleet tool; gh-axi is already stubbed above
# because it also serves the release-list lookup.
mk_stub chrome-devtools-axi 'printf "0.1.29\n"'
mk_stub lavish-axi 'printf "0.1.50\n"'
mk_stub tasks-axi 'printf "0.2.5\n"'
mk_stub quota-axi 'printf "0.1.21\n"'
mk_stub gnhf 'printf "0.1.43\n"'
mk_stub pi 'printf "0.84.1\n"'
mk_stub no-mistakes 'printf "v1.41.2 (867d64d)\n"'
mk_stub treehouse 'printf "v2.1.0\n"'
mk_stub gbrain 'printf "0.45.9.0\n"'
mk_stub herdr 'printf "0.8.0\n"'

# Restricted PATH: the fakebin plus core utilities only, so host fleet tools
# cannot leak in and the stubs are provably the ones consulted.
PATH="$FAKEBIN:/usr/bin:/bin" "$TOOL" >"$TMP/report.txt" 2>&1
rc=$?
REPORT=$(cat "$TMP/report.txt")
[ "$rc" -eq 0 ] || fail "report: exits 0 (rc=$rc)"
pass "report: exits 0"

report_row() { # report_row <tool> <grep-ERE> <label>
  printf '%s\n' "$REPORT" | grep -E "^$1 +.*$2" >/dev/null \
    || fail "report: $3; row: $(printf '%s\n' "$REPORT" | grep "^$1 " || true)"
pass "report: $3"
}
report_row gh-axi '0\.1\.30 +0\.1\.2[0-9] +0\.1\.30 +npm +current$' "current tool reported current"
report_row quota-axi '0\.1\.21 +0\.1\.1[0-9] +0\.1\.28 +npm +behind$' "behind tool reported behind with floor beside install"
report_row no-mistakes '1\.41\.2 +1\.31\.2 +1\.48\.0 +github +behind; pre-releases up to v1\.51\.0 excluded$' "GA latest, pre-releases above it named"
report_row treehouse '2\.1\.0 +none +2\.1\.1 +github +behind$' "github channel latest parsed"
report_row gbrain '0\.45\.9\.0 +none +0\.45\.14\.0 +github +behind$' "four-segment versions compared"
report_row herdr '0\.8\.0 +none +0\.8\.0 +herdr +current; pre-releases up to preview-2026-08-04 excluded$' "herdr latest.json plus preview note"
report_row pi '0\.84\.1 +none +0\.84\.2 +npm +behind$' "pi tracked under its npm package name"
report_row gnhf '0\.1\.43 +none +- +npm +could-not-verify \(npm view gnhf version\)$' "failed lookup degrades honestly, naming the command"

# The read-only contract, asserted from what the stubs actually saw.
grep -q '^npm view ' "$LOG" || fail "read-only: npm log missing"
pass "read-only: npm log captured"
[ "$(grep -c '^npm ' "$LOG")" -eq "$(grep -c '^npm view ' "$LOG")" ] \
  || fail "read-only: npm called with something other than view: $(grep '^npm ' "$LOG" | grep -v '^npm view ' || true)"
pass "read-only: npm only ever called with view"
grep -q '^gh-axi release list ' "$LOG" || fail "read-only: gh-axi log missing"
pass "read-only: gh-axi release list captured"
if grep '^gh-axi ' "$LOG" | grep -Ev '^gh-axi (--version|release list )' >/dev/null; then
  fail "read-only: gh-axi called beyond --version and release list: $(grep '^gh-axi ' "$LOG" | grep -Ev '^gh-axi (--version|release list )')"
else
  pass "read-only: gh-axi only ever called with --version and release list"
fi
if grep -Eq 'install|update|setup hooks|daemon' "$LOG"; then
  fail "read-only: a mutating verb reached a stub: $(grep -E 'install|update|setup hooks|daemon' "$LOG")"
else
  pass "read-only: no install, update, setup hooks, or daemon call anywhere"
fi
if grep -q 'invocations.log' "$TMP/report.txt"; then
  fail "report: stub internals leaked into report output"
else
  pass "report: no stub diagnostics leak into output"
fi

# A not-installed tool (gnhf absent from a fresh fakebin) degrades to a named
# verdict instead of borrowing the host's real gnhf.
FAKEBIN2=$(fm_fakebin "$TMP/missing")
for f in "$FAKEBIN"/*; do
  base=$(basename "$f")
  [ "$base" = gnhf ] && continue
  [ "$base" = invocations.log ] && continue
  ln -s "$f" "$FAKEBIN2/$base"
done
LOG2="$FAKEBIN2/invocations.log"
: >"$LOG2"
REPORT2=$(PATH="$FAKEBIN2:/usr/bin:/bin" "$TOOL" 2>&1)
printf '%s\n' "$REPORT2" | grep -E '^gnhf +- +none +- +npm +not-installed$' >/dev/null \
  || fail "report: absent tool must read not-installed; row: $(printf '%s\n' "$REPORT2" | grep '^gnhf ' || true)"
pass "report: absent tool reported not-installed"

# Floors resolve from any working directory, not just the repo root.
FLOORS_ELSEWHERE=$(cd /tmp && "$TOOL" floors)
printf '%s\n' "$FLOORS_ELSEWHERE" | grep -q 'fm-tasks-axi-lib.sh' \
  || fail "floors: must resolve floor files from any cwd"
pass "floors: resolve from a foreign cwd"

printf '\nall fm-tool-status tests passed\n'
