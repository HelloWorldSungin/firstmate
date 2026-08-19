#!/usr/bin/env bash
# fm-gbrain-pin-check.sh - fail when docs/gbrain.md's recorded GBrain pin
# disagrees with the release actually installed on this host.
#
# Usage:
#   fm-gbrain-pin-check.sh [--json] [--gbrain <path>]
#   fm-gbrain-pin-check.sh --help
#
# Options:
#   --json      emit one fm-gbrain-pin-check.v1 object instead of prose.
#   --gbrain    the executable to ask for its version, instead of the one
#               FM_GBRAIN_BIN names. Naming a path asserts it should be there,
#               so one that is missing or not executable is `unknown`, never
#               `skipped`.
#
# Environment:
#   FM_GBRAIN_BIN  gbrain executable (default: gbrain on PATH), read only for
#                  its --version. Setting it asserts that executable should be
#                  there, so one that does not resolve is `unknown` too.
#
# Why this exists: docs/gbrain.md's upgrade policy requires the recorded pin to
# move in the same change that performs an upgrade, and the dashboard's GBrain
# panel quotes that recorded string rather than asking a running executable.
# Nothing enforced that, so an upgrade could land and leave the record - and
# therefore the panel - describing a release the fleet no longer runs. This is
# the mechanical reader of both sides.
#
# This command is READ-ONLY. It reads docs/gbrain.md and runs `<gbrain>
# --version`, and nothing else. It never touches a brain, a database, or a
# migration.
#
# Verdicts and exit codes:
#   ok        0  the recorded pin and the installed release agree.
#   drift     1  they disagree; the record is stale or the host is not on the
#                pinned release. Either way it is a finding, because the two
#                are supposed to move together.
#   skipped   0  nothing named a gbrain and none is on PATH, so there is
#                nothing to compare against. CI and a fresh worktree land here,
#                and that is a genuine absence of evidence rather than a pass.
#                It is the only exit 0 that did not compare two releases.
#   unknown   2  a side could not be read: no docs/gbrain.md, no parseable pin
#                token in it, a recorded pin carrying no dotted release number,
#                a --gbrain or FM_GBRAIN_BIN that does not resolve to an
#                executable, or an installed executable whose --version output
#                does not carry a version. Reported, never treated as ok.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gbrain-lib.sh
. "$SELF_DIR/fm-gbrain-lib.sh"

usage() {
  awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
}

JSON=false
GBRAIN_BIN=""
GBRAIN_EXPLICIT=false
while [ $# -gt 0 ]; do
  case $1 in
    --json) JSON=true ;;
    --gbrain)
      shift
      [ $# -gt 0 ] || { printf 'fm-gbrain-pin-check: --gbrain needs a path\n' >&2; exit 2; }
      GBRAIN_BIN=$1
      GBRAIN_EXPLICIT=true
      ;;
    --gbrain=*) GBRAIN_BIN=${1#--gbrain=}; GBRAIN_EXPLICIT=true ;;
    -h | --help) usage; exit 0 ;;
    *)
      printf 'fm-gbrain-pin-check: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

# Compare on the numeric release only. The record writes the tag (v0.46.21.0)
# and the executable prints a bare version (gbrain 0.46.21.0); the leading v is
# a tag convention, not a difference between the two releases.
release_number() {  # <any string> -> dotted numeric version, or nothing
  printf '%s\n' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

version_evidence() {  # first non-empty line either stream of the read produced
  printf '%s\n' "$VERSION_OUT" | grep -m1 . && return 0
  grep -m1 . "$VERSION_STDERR" 2>/dev/null || true
}

emit() {  # <verdict> <exit-code> <detail>
  local verdict=$1 code=$2 detail=$3
  if [ "$JSON" = true ]; then
    jq -n \
      --arg schema fm-gbrain-pin-check.v1 \
      --arg verdict "$verdict" \
      --arg documented "$DOCUMENTED" \
      --arg installed "$INSTALLED" \
      --arg detail "$detail" \
      '{schema: $schema, verdict: $verdict,
        documented: (if $documented == "" then null else $documented end),
        installed: (if $installed == "" then null else $installed end),
        detail: $detail}'
  elif [ "$code" -eq 0 ]; then
    printf 'fm-gbrain-pin-check: %s - %s\n' "$verdict" "$detail"
  else
    printf 'fm-gbrain-pin-check: %s - %s\n' "$verdict" "$detail" >&2
  fi
  exit "$code"
}

DOCUMENTED=""
INSTALLED=""

# Read in the current shell, never through a command substitution: the reason a
# read failed lives in FM_GBRAIN_ERROR, and a subshell would take it with it and
# leave every doc-side unknown reporting an empty detail.
fm_gbrain_documented_pin "$FM_ROOT" || emit unknown 2 "$FM_GBRAIN_ERROR"
DOCUMENTED=$FM_GBRAIN_PIN
DOCUMENTED_NUMBER=$(release_number "$DOCUMENTED")
[ -n "$DOCUMENTED_NUMBER" ] \
  || emit unknown 2 "docs/gbrain.md records \"$DOCUMENTED\", which carries no dotted release number, so the record could not be read as a release"

# Anything that NAMES an executable - the flag or FM_GBRAIN_BIN - has asserted
# it should be there, so one that does not resolve is a side that could not be
# read. Only nothing naming one and none on PATH is an absent brain, which is
# the single verdict allowed to exit 0 without comparing two releases.
# Resolution itself is `command -v` over ${FM_GBRAIN_BIN:-gbrain}, the shape
# every other gbrain-touching script already uses.
if [ "$GBRAIN_EXPLICIT" = true ]; then
  [ -x "$GBRAIN_BIN" ] \
    || emit unknown 2 "--gbrain named \"$GBRAIN_BIN\", which is not an executable file, so the installed release could not be read"
elif [ -n "${FM_GBRAIN_BIN:-}" ]; then
  GBRAIN_BIN=$(command -v "$FM_GBRAIN_BIN" 2>/dev/null || true)
  [ -n "$GBRAIN_BIN" ] && [ -x "$GBRAIN_BIN" ] \
    || emit unknown 2 "FM_GBRAIN_BIN named \"$FM_GBRAIN_BIN\", which does not resolve to an executable, so the installed release could not be read"
else
  GBRAIN_BIN=$(command -v gbrain 2>/dev/null || true)
  [ -n "$GBRAIN_BIN" ] && [ -x "$GBRAIN_BIN" ] \
    || emit skipped 0 "no gbrain executable on this host, so the recorded pin $DOCUMENTED was compared against nothing"
fi

VERSION_OUT=""
VERSION_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-gbrain-pin-check.XXXXXX") \
  || emit unknown 2 "no temporary file could be created, so $GBRAIN_BIN --version was never read"
trap 'rm -f "$VERSION_STDERR"' EXIT

# The release is parsed from stdout alone. gbrain writes upgrade-availability
# banners carrying a SECOND version to stderr on the non-TTY path every caller
# here takes, and a merged stream would let that one be read as the installed
# release and reported as drift on every host at once. Both streams still feed
# the detail an unknown prints, because that is evidence rather than a version.
VERSION_OUT=$("$GBRAIN_BIN" --version 2>"$VERSION_STDERR") || {
  emit unknown 2 "$GBRAIN_BIN --version failed: $(version_evidence)"
}
INSTALLED=$(release_number "$VERSION_OUT")
[ -n "$INSTALLED" ] || emit unknown 2 "$GBRAIN_BIN --version printed no version: $(version_evidence)"

if [ "$DOCUMENTED_NUMBER" = "$INSTALLED" ]; then
  emit ok 0 "docs/gbrain.md records $DOCUMENTED and $GBRAIN_BIN is $INSTALLED"
fi

emit drift 1 "docs/gbrain.md records $DOCUMENTED but $GBRAIN_BIN is $INSTALLED; move the recorded pin and the clean-install recipe commit together, per docs/gbrain.md's upgrade policy"
