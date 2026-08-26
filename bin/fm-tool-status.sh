#!/usr/bin/env bash
# fm-tool-status.sh - read-only "what's behind" report for this home's toolchain.
# Usage:
#   fm-tool-status.sh                    print the full staleness report
#   fm-tool-status.sh floors             print each floor, its value, and its source file
#   fm-tool-status.sh latest-ga <v>...   print the highest non-pre-release candidate
#   fm-tool-status.sh release-ga         parse `gh-axi release list` rows from stdin
#   fm-tool-status.sh version-gte <a> <b>  exit 0 when version a >= version b
#   fm-tool-status.sh --help             print this usage
#
# This script is READ-ONLY. It runs `<tool> --version`, `npm view`, `gh-axi
# release list`, and `curl https://herdr.dev/latest.json`, and nothing else.
# It never installs, upgrades, or runs a `setup hooks` command, and it never
# mutates the host or the repository.
#
# Distribution channels, because assuming one channel for every tool is the
# mistake this script exists to prevent:
#   npm     - the axi family, gnhf, and pi (package @earendil-works/pi-coding-agent).
#             `npm view <pkg> version` is authoritative (the latest dist-tag
#             never points at a pre-release).
#   github  - no-mistakes, treehouse, and gbrain install from GitHub releases,
#             so their upstream is a repository read via `gh-axi release list`,
#             never npm. The latest GA release is the newest row not flagged
#             pre-release or draft; the highest version number is NOT the
#             latest release (no-mistakes has shipped pre-releases above GA).
#   herdr   - https://herdr.dev/latest.json is the primary source, with the
#             GitHub releases list as a second read so dated preview builds
#             above GA are visible rather than mistaken for the latest.
#
# Version floors are read live from their owning files, never copied here:
# GH_AXI_MIN, LAVISH_AXI_MIN, CHROME_DEVTOOLS_AXI_MIN, and NO_MISTAKES_MIN in
# bin/fm-bootstrap.sh; FM_TASKS_AXI_MIN in bin/fm-tasks-axi-lib.sh;
# FM_QUOTA_AXI_MIN in bin/fm-quota-axi-lib.sh.
# The axi-family floor policy is owned beside those constants.
#
# Degrade honestly: a failed lookup for one tool prints could-not-verify with
# the command that failed. It never silently skips a tool and never assumes
# installed equals latest. The exit code is 0 for any completed report, even
# one with could-not-verify rows; only usage errors exit non-zero.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

# Tool inventory: name|channel|ref|floor-var|floor-file-key
#   channel  npm (ref = npm package), github (ref = owner/repo), herdr
#   ref      npm package name, or the owner/repo to list releases from
#   floor-*  the floor variable's name and the file that owns it, empty = none
# npm package `axi` is deliberately absent: it is an unrelated empty placeholder
# that this fleet must never go looking for.
FM_TOOL_TABLE=(
  "gh-axi|npm|gh-axi|GH_AXI_MIN|fm-bootstrap"
  "chrome-devtools-axi|npm|chrome-devtools-axi|CHROME_DEVTOOLS_AXI_MIN|fm-bootstrap"
  "lavish-axi|npm|lavish-axi|LAVISH_AXI_MIN|fm-bootstrap"
  "tasks-axi|npm|tasks-axi|FM_TASKS_AXI_MIN|fm-tasks-axi-lib"
  "quota-axi|npm|quota-axi|FM_QUOTA_AXI_MIN|fm-quota-axi-lib"
  "gnhf|npm|gnhf||"
  "pi|npm|@earendil-works/pi-coding-agent||"
  "no-mistakes|github|kunchenguid/no-mistakes|NO_MISTAKES_MIN|fm-bootstrap"
  "treehouse|github|kunchenguid/treehouse||"
  "gbrain|github|garrytan/gbrain||"
  "herdr|herdr|herdrdev/herdr||"
)

usage() {
  awk 'NR>1 && /^#/ { if ($0 == "#") exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# --- pure version logic (the tested core; no network, no host state) --------

# normalize_version <any string>: echo the first dotted numeric version in the
# string, with any leading v/V already dropped by the match itself, or nothing.
normalize_version() {
  printf '%s\n' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

# version_gte <a> <b>: numeric segment-by-segment compare, missing segments
# count as zero (gbrain ships four segments), lexicographic order never applies
# (0.1.9 > 0.1.10 is exactly the bug this prevents).
version_gte() {
  local a b
  a=$(normalize_version "$1") || true
  b=$(normalize_version "$2") || true
  [ -n "$a" ] && [ -n "$b" ] || return 2
  local -a av bv
  IFS='.' read -r -a av <<<"$a"
  IFS='.' read -r -a bv <<<"$b"
  local n=${#av[@]} i x y
  [ "${#bv[@]}" -gt "$n" ] && n=${#bv[@]}
  for ((i = 0; i < n; i++)); do
    x=${av[i]:-0}
    y=${bv[i]:-0}
    x=${x//[!0-9]/}
    y=${y//[!0-9]/}
    [ -z "$x" ] && x=0
    [ -z "$y" ] && y=0
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

# is_prerelease <version>: a hyphen suffix (1.51.0-rc1, preview-2026-08-04) or
# an embedded rc/beta/alpha/preview/pre marker marks a candidate as not GA.
# The GA-latest filter calls this on every GitHub tag even when the release row
# itself is not flagged pre-release, because herdr publishes dated preview
# builds that GitHub does not always flag.
is_prerelease() {
  local v=${1#v}
  case $v in
    *-*) return 0 ;;
  esac
  v=${v,,}
  case $v in
    *rc* | *beta* | *alpha* | *preview* | *pre*) return 0 ;;
  esac
  return 1
}

# latest_ga <v>...: echo the highest non-pre-release candidate, or nothing.
latest_ga() {
  local v best=""
  for v in "$@"; do
    is_prerelease "$v" && continue
    if [ -z "$best" ] || version_gte "$v" "$best"; then best=$v; fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
  [ -n "$best" ]
}

# release_ga_rows: consume `gh-axi release list` output on stdin and set
# GA_TAG to the newest release that is neither draft nor pre-release (by flag
# or by tag shape) and PRE_TAG to the newest pre-release above it (or none).
# Rows look like "  v1.51.0,v1.51.0,no,yes,17h ago" (tag,name,draft,prerelease,published);
# header lines and unparseable rows are skipped, never guessed from.
release_ga_rows() {
  GA_TAG=""
  PRE_TAG=""
  local line tag _name draft pre _rest
  while IFS= read -r line; do
    case $line in
      '  '*) ;;
      *) continue ;;
    esac
    IFS=',' read -r tag _name draft pre _rest <<<"$line"
    tag=${tag//[[:space:]]/}
    draft=${draft//[[:space:]]/}
    pre=${pre//[[:space:]]/}
    [ -n "$tag" ] || continue
    if [ "$draft" = "yes" ] || [ "$pre" = "yes" ] || is_prerelease "$tag"; then
      [ -z "$PRE_TAG" ] && PRE_TAG=$tag
      continue
    fi
    GA_TAG=$tag
    return 0
  done
}

# --- read-only host and network reads ----------------------------------------

# readonly_run: run a read-only lookup under a bounded timeout when one exists.
# Stdin is left as the caller set it: the jq pipe below depends on it.
readonly_run() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# installed_version <tool>: echo the parsed installed version, or fail with
# 1 = not installed, 2 = --version failed, 3 = output unparseable.
installed_version() {
  local tool=$1 out
  command -v "$tool" >/dev/null 2>&1 || return 1
  out=$(readonly_run "$tool" --version) || return 2
  out=$(normalize_version "$out")
  [ -n "$out" ] || return 3
  printf '%s\n' "$out"
}

# floor_file <file-key>
floor_file() {
  case $1 in
    fm-bootstrap) printf '%s\n' "$ROOT/bin/fm-bootstrap.sh" ;;
    fm-tasks-axi-lib) printf '%s\n' "$ROOT/bin/fm-tasks-axi-lib.sh" ;;
    fm-quota-axi-lib) printf '%s\n' "$ROOT/bin/fm-quota-axi-lib.sh" ;;
    *) return 1 ;;
  esac
}

# floor_value <var> <file-key>: echo the floor assignment from its owning file,
# or nothing. Reading the owning file live is the point: this script holds no
# copy of any floor number.
floor_value() {
  local var=$1 key=$2 file
  file=$(floor_file "$key") || return 1
  [ -f "$file" ] || return 1
  awk -v pat="^${var}=" '$0 ~ pat { sub(pat, ""); print; exit }' "$file"
}

# --- the subcommands ----------------------------------------------------------

cmd_latest_ga() {
  [ $# -ge 1 ] || { usage >&2; return 2; }
  latest_ga "$@"
  return $?
}

cmd_version_gte() {
  [ $# -eq 2 ] || { usage >&2; return 2; }
  version_gte "$1" "$2"
  return $?
}

cmd_release_ga() {
  local ga pre
  release_ga_rows
  ga=${GA_TAG:-none}
  pre=${PRE_TAG:-none}
  printf 'ga=%s\npre=%s\n' "$ga" "$pre"
}

cmd_floors() {
  local entry name _channel _ref floorvar floorkey value file
  printf '%-20s %-18s %-9s %s\n' "tool" "floor" "value" "source"
  for entry in "${FM_TOOL_TABLE[@]}"; do
    IFS='|' read -r name _channel _ref floorvar floorkey <<<"$entry"
    if [ -z "$floorvar" ]; then
      printf '%-20s %-18s %-9s %s\n' "$name" "none" "-" "no floor by design"
      continue
    fi
    file=$(floor_file "$floorkey") || file="?"
    value=$(floor_value "$floorvar" "$floorkey")
    [ -n "$value" ] || value="unreadable"
    printf '%-20s %-18s %-9s %s\n' "$name" "$floorvar" "$value" "$file"
  done
}

# Report helpers: latest_for sets LATEST and NOTE, or fails with LATEST_ERR.
LATEST=""
LATEST_ERR=""
NOTE=""

latest_npm() {
  local pkg=$1 out
  command -v npm >/dev/null 2>&1 || {
    LATEST_ERR="could-not-verify (npm not found)"
    return 1
  }
  out=$(readonly_run npm view "$pkg" version) || {
    LATEST_ERR="could-not-verify (npm view $pkg version)"
    return 1
  }
  out=$(normalize_version "$out")
  [ -n "$out" ] || {
    LATEST_ERR="could-not-verify (npm view $pkg version: unparseable output)"
    return 1
  }
  LATEST=$out
}

github_releases() {
  local repo=$1 out
  command -v gh-axi >/dev/null 2>&1 || {
    LATEST_ERR="could-not-verify (gh-axi not found)"
    return 1
  }
  out=$(readonly_run gh-axi release list --repo "$repo" --limit 30) || {
    LATEST_ERR="could-not-verify (gh-axi release list --repo $repo)"
    return 1
  }
  release_ga_rows <<<"$out"
}

latest_github() {
  local repo=$1
  github_releases "$repo" || return 1
  if [ -z "$GA_TAG" ]; then
    LATEST_ERR="could-not-verify (gh-axi release list --repo $repo: no GA release)"
    return 1
  fi
  LATEST=$(normalize_version "$GA_TAG")
  [ -n "$LATEST" ] || {
    LATEST_ERR="could-not-verify (gh-axi release list --repo $repo: unparseable tag $GA_TAG)"
    return 1
  }
  [ -z "$PRE_TAG" ] || NOTE="pre-releases up to $PRE_TAG excluded"
}

latest_herdr() {
  local repo=$1 json out
  command -v curl >/dev/null 2>&1 || {
    LATEST_ERR="could-not-verify (curl not found)"
    return 1
  }
  json=$(readonly_run curl -fsSL https://herdr.dev/latest.json) || {
    LATEST_ERR="could-not-verify (curl -fsSL https://herdr.dev/latest.json)"
    return 1
  }
  out=$(printf '%s\n' "$json" | jq -r '.version // empty' 2>/dev/null) || {
    LATEST_ERR="could-not-verify (jq parse of https://herdr.dev/latest.json)"
    return 1
  }
  out=$(normalize_version "$out")
  [ -n "$out" ] || {
    LATEST_ERR="could-not-verify (https://herdr.dev/latest.json: no version field)"
    return 1
  }
  LATEST=$out
  # Second read, from the releases list, so a preview above GA is a note
  # rather than a silent disagreement between the two sources.
  if github_releases "$repo"; then
    [ -z "$PRE_TAG" ] || NOTE="pre-releases up to $PRE_TAG excluded"
  else
    NOTE="github releases could-not-verify; latest.json only"
  fi
}

cmd_report() {
  local entry name channel ref floorvar floorkey
  local installed installed_rc installed_verdict floor latest verdict
  printf 'toolchain staleness report %s (read-only; versions read live)\n\n' "$(date -u +%Y-%m-%d)"
  printf '%-20s %-12s %-9s %-12s %-7s %s\n' "tool" "installed" "floor" "latest" "channel" "verdict"
  for entry in "${FM_TOOL_TABLE[@]}"; do
    IFS='|' read -r name channel ref floorvar floorkey <<<"$entry"
    installed=$(installed_version "$name" 2>/dev/null)
    installed_rc=$?
    installed_verdict=""
    case $installed_rc in
      0) ;;
      1)
        installed="-"
        installed_verdict="not-installed"
        ;;
      2)
        installed="-"
        installed_verdict="could-not-verify ($name --version)"
        ;;
      3)
        installed="-"
        installed_verdict="could-not-verify ($name --version: unparseable output)"
        ;;
      *)
        installed="-"
        installed_verdict="could-not-verify ($name --version: unexpected failure)"
        ;;
    esac
    floor="none"
    if [ -n "$floorvar" ]; then
      floor=$(floor_value "$floorvar" "$floorkey")
      [ -n "$floor" ] || floor="unreadable"
    fi
    LATEST=""
    LATEST_ERR=""
    NOTE=""
    case $channel in
      npm) latest_npm "$ref" ;;
      github) latest_github "$ref" ;;
      herdr) latest_herdr "$ref" ;;
    esac
    latest=${LATEST:-"-"}
    verdict=$installed_verdict
    if [ -n "$LATEST_ERR" ]; then
      [ -z "$verdict" ] || verdict="$verdict; "
      verdict="${verdict}${LATEST_ERR}"
    elif [ "$installed" != "-" ] && version_gte "$installed" "$latest"; then
      verdict="current"
    elif [ "$installed" != "-" ]; then
      verdict="behind"
    fi
    if [ "$installed" != "-" ] && [ "$floor" != "none" ] && [ "$floor" != "unreadable" ]; then
      version_gte "$installed" "$floor" || verdict="$verdict; below floor"
    fi
    [ -z "$NOTE" ] || verdict="$verdict; $NOTE"
    printf '%-20s %-12s %-9s %-12s %-7s %s\n' "$name" "$installed" "$floor" "$latest" "$channel" "$verdict"
  done
}

case ${1:-report} in
  report) cmd_report ;;
  floors) cmd_floors ;;
  latest-ga) shift; cmd_latest_ga "$@" ;;
  version-gte) shift; cmd_version_gte "$@" ;;
  release-ga) cmd_release_ga ;;
  -h | --help | help) usage ;;
  *)
    printf 'unknown subcommand: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
