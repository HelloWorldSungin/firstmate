#!/usr/bin/env bash
# Resolve a harness name to its harness-adapters variant file.
# Usage: fm-harness-adapter-doc.sh <harness>           print the variant file's path
#        fm-harness-adapter-doc.sh --print <harness>   print the variant file's contents
#        fm-harness-adapter-doc.sh --list              print every harness name that resolves
#
# .agents/skills/harness-adapters/SKILL.md is a shared head plus one variant file
# per harness, so a spawn loads the head and the one adapter it is about to act on
# instead of all nine. This script is the routing owner: the head's table is a
# reader's index, and every automated or agent lookup comes through here.
#
# It exists to make the failure loud. A split reference degrades badly when a
# lookup half-succeeds - an agent that cannot find grok's exit path and answers
# from the shared head alone has produced a confident wrong answer about a pane
# already waiting on a trust dialog. So an unknown harness name and an
# unreadable variant file are both hard refusals naming what failed, never a
# silent fallback to the head.
#
# Exit status: 0 resolved; 2 unknown harness name; 3 variant file missing or
# unreadable; 64 usage error.
#
# `pi` and `pi-signed` deliberately share one variant: they are one verified
# adapter with two launch identities, and duplicating the file would put the same
# facts in two places for the one-owner rule to rot (docs/one-owner.md).
#
# Adding a verified adapter means adding its row to HARNESS_DOCS below AND
# creating the variant file. Until both land this script refuses that harness by
# name, which is the intended behavior: no variant file means no verified
# per-harness knowledge to serve.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DOC_DIR="$FM_ROOT/.agents/skills/harness-adapters/harnesses"

# Routing table: "<harness> <variant-file-basename>", one per line.
HARNESS_DOCS="claude claude.md
codex codex.md
opencode opencode.md
pi pi.md
pi-signed pi.md
grok grok.md
kimi kimi.md
cursor cursor.md
muse muse.md
agy agy.md"

usage() {
  sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

known_names() {
  printf '%s\n' "$HARNESS_DOCS" | awk '{print $1}'
}

MODE=path
case "${1-}" in
  --list)
    known_names
    exit 0
    ;;
  --print)
    MODE=print
    shift
    ;;
  --path)
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "error: unknown option '$1'" >&2
    usage
    exit 64
    ;;
esac

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "error: expected exactly one harness name" >&2
  usage
  exit 64
fi

HARNESS="$1"

DOC_NAME="$(printf '%s\n' "$HARNESS_DOCS" | awk -v h="$HARNESS" '$1 == h {print $2; exit}')"

if [ -z "$DOC_NAME" ]; then
  # Named refusal, never a fallback to the shared head: see the header.
  echo "error: '$HARNESS' is not a harness with an adapter variant file." >&2
  echo "       resolvable names: $(known_names | tr '\n' ' ')" >&2
  echo "       'default' and 'unknown' are resolution results, not harnesses: resolve them through bin/fm-harness.sh first." >&2
  echo "       A newly verified adapter needs its variant file and its row in $(basename "${BASH_SOURCE[0]}") before it resolves." >&2
  exit 2
fi

DOC_PATH="$DOC_DIR/$DOC_NAME"

if [ ! -f "$DOC_PATH" ] || [ ! -r "$DOC_PATH" ]; then
  echo "error: the adapter variant file for '$HARNESS' is missing or unreadable: $DOC_PATH" >&2
  echo "       Do not answer a '$HARNESS' question from the shared head alone; restore the file first." >&2
  exit 3
fi

if [ "$MODE" = print ]; then
  cat "$DOC_PATH"
else
  printf '%s\n' "$DOC_PATH"
fi
