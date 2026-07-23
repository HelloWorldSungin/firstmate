#!/usr/bin/env bash
# Structural regression tests for the tracked documentation audience inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-doc-audience-check.sh"
INVENTORY="$ROOT/docs/documentation-audiences.json"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-doc-audiences.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

mutate_inventory() {
  local source=$1 destination=$2 mode=$3
  python3 - "$source" "$destination" "$mode" <<'PY'
import json
import sys
from pathlib import Path

source, destination, mode = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
if mode.name == "duplicate":
    data["surfaces"].append(dict(data["surfaces"][0]))
elif mode.name == "bad-setup-audience":
    for entry in data["surfaces"]:
        if entry["path"] == "docs/tmux-backend.md":
            entry["audience"] = "maintainer-verification"
            break
elif mode.name == "missing-owner-pointer":
    data["requiredOwnerPointers"][0] = {
        "source": "README.md",
        "target": "docs/sessionstart-nudge.md",
    }
elif mode.name == "shrink-scope":
    data["scope"]["trackedPatterns"] = ["README.md"]
else:
    raise SystemExit(f"unknown mode: {mode.name}")
destination.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

test_repository_inventory_passes() {
  local out
  out=$("$CHECK") || fail "repository documentation audience check failed"
  assert_contains "$out" "fm-doc-audience-check: ok surfaces=" \
    "audience check did not report exact surface coverage"
  assert_contains "$out" "local_links=" \
    "audience check did not report local-link validation"
  pass "documentation inventory classifies every maintained prose surface exactly once"
}

test_duplicate_and_setup_classification_fail() {
  local duplicate="$TMP_ROOT/duplicate.json"
  local bad_setup="$TMP_ROOT/bad-setup.json"
  local shrink_scope="$TMP_ROOT/shrink-scope.json"
  mutate_inventory "$INVENTORY" "$duplicate" duplicate
  mutate_inventory "$INVENTORY" "$bad_setup" bad-setup-audience
  mutate_inventory "$INVENTORY" "$shrink_scope" shrink-scope
  run_expect_failure "surfaces classified more than once" \
    "$CHECK" --inventory "$duplicate"
  run_expect_failure "README setup target docs/tmux-backend.md has disallowed audience" \
    "$CHECK" --inventory "$bad_setup"
  run_expect_failure "scope.trackedPatterns must match the fixed maintained-prose scope" \
    "$CHECK" --inventory "$shrink_scope"
  pass "classification, setup routing, and maintained-prose scope fail safely"
}

test_required_pointer_fails() {
  local missing_pointer="$TMP_ROOT/missing-pointer.json"
  mutate_inventory "$INVENTORY" "$missing_pointer" missing-owner-pointer
  run_expect_failure "required owner pointer missing" \
    "$CHECK" --inventory "$missing_pointer"
  pass "required documentation owner pointers cannot silently disappear"
}

write_fixture_inventory() {
  local repo=$1
  cat > "$repo/docs/documentation-audiences.json" <<'JSON'
{
  "version": 1,
  "scope": {"trackedPatterns": ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]},
  "allowedAudiences": ["public-product", "operator-current", "maintainer-verification"],
  "setupAudiences": ["public-product", "operator-current"],
  "readmeSetupTargets": ["docs/setup.md"],
  "requiredOwnerPointers": [
    {"source": "README.md", "target": "docs/policy.md"}
  ],
  "surfaces": [
    {"path": "README.md", "audience": "public-product"},
    {"path": "docs/evidence.md", "audience": "maintainer-verification"},
    {"path": "docs/guide.rst", "audience": "operator-current"},
    {"path": "docs/policy.md", "audience": "operator-current"},
    {"path": "docs/protocol_(v1).md", "audience": "operator-current"},
    {"path": "docs/setup.md", "audience": "operator-current"},
    {"path": "docs/source.md", "audience": "operator-current"},
    {"path": "docs/target.md", "audience": "operator-current"}
  ]
}
JSON
}

test_local_links_and_no_keyword_heuristic() {
  local repo="$TMP_ROOT/fixture"
  mkdir -p "$repo/docs"
  git -C "$repo" init -q
  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md)' > "$repo/README.md"
  printf '%s\n' '# Setup' > "$repo/docs/setup.md"
  printf '%s\n' '# Policy' > "$repo/docs/policy.md"
  printf '%s\n' '# Protocol' > "$repo/docs/protocol_(v1).md"
  printf '%s\n' 'Guide' '=====' '' 'See `setup`_.' '' '.. _setup: setup.md' > "$repo/docs/guide.rst"
  printf '%s\n' '[Target](target.md#real-heading)' > "$repo/docs/source.md"
  printf '%s\n' '# Real heading' > "$repo/docs/target.md"
  cat > "$repo/docs/evidence.md" <<'MD'
# Incident verification on 2026-07-23

```sh
/tmp/task-worktree/bin/tool --version
```

Observed version 1.2.3 on branch `fm/example`.
MD
  write_fixture_inventory "$repo"
  git -C "$repo" add README.md docs
  "$CHECK" --root "$repo" >/dev/null \
    || fail "structural checker rejected legitimate maintainer evidence prose"

  cat > "$repo/README.md" <<'MD'
[Setup](docs/setup.md) [Policy](docs/policy.md) [Balanced](docs/protocol_(v1).md) [Escaped](docs/protocol_\(v1\).md "Protocol")

`[Inline Markdown example](docs/missing-inline.md)` and `<a href="docs/missing-inline.html">inline HTML example</a>`.

```markdown
[Fenced Markdown example](docs/missing-fenced.md)
<img src="docs/missing-fenced.png">
```

    [Indented Markdown example](docs/missing-indented.md)
    <a href="docs/missing-indented.html">indented HTML example</a>

> ~~~markdown
> [Blockquoted Markdown example](docs/missing-blockquoted.md)
> <img src="docs/missing-blockquoted.png">
> ~~~
MD
  git -C "$repo" add README.md
  "$CHECK" --root "$repo" >/dev/null \
    || fail "structural checker rejected valid links or code examples"

  cat > "$repo/README.md" <<'MD'
[Setup](docs/setup.md) [Policy](docs/policy.md)

- Nested documentation:
    [Broken nested link](docs/missing-nested.md)
MD
  git -C "$repo" add README.md
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"

  cat > "$repo/README.md" <<'MD'
[Setup][setup] [Policy](docs/policy.md)

[setup]: docs/setup.md
[missing]:
  docs/missing-reference.md
MD
  git -C "$repo" add README.md
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"

  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md)' > "$repo/README.md"
  printf '%s\n' 'Guide' '=====' '' 'See `missing`_.' '' '.. _missing: missing.rst' > "$repo/docs/guide.rst"
  git -C "$repo" add README.md docs/guide.rst
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"

  cat > "$repo/docs/guide.rst" <<'RST'
Guide
=====

Anonymous__

__ missing-anonymous.rst
RST
  git -C "$repo" add docs/guide.rst
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"

  cat > "$repo/docs/guide.rst" <<'RST'
Guide
=====

.. code:: rst

   `Code example <missing-code.rst>`_

.. note::

   `Policy <policy.md>`_
RST
  git -C "$repo" add docs/guide.rst
  "$CHECK" --root "$repo" >/dev/null \
    || fail "structural checker confused parsed and literal reStructuredText directives"

  sed 's/code:: rst/parsed-literal::/' "$repo/docs/guide.rst" > "$repo/docs/guide.rst.tmp"
  mv "$repo/docs/guide.rst.tmp" "$repo/docs/guide.rst"
  git -C "$repo" add docs/guide.rst
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"

  sed 's/parsed-literal::/code:: rst/' "$repo/docs/guide.rst" > "$repo/docs/guide.rst.tmp"
  mv "$repo/docs/guide.rst.tmp" "$repo/docs/guide.rst"
  sed 's/policy.md/missing-note.rst/' "$repo/docs/guide.rst" > "$repo/docs/guide.rst.tmp"
  mv "$repo/docs/guide.rst.tmp" "$repo/docs/guide.rst"
  git -C "$repo" add docs/guide.rst
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"

  printf '%s\n' 'Guide' '=====' '' 'See `setup`_.' '' '.. _setup: setup.md' > "$repo/docs/guide.rst"
  printf '%s\n' '# Real heading' '' '```markdown' '# Example' '```' > "$repo/docs/target.md"
  printf '%s\n' '[Code-only anchor](target.md#example)' > "$repo/docs/source.md"
  git -C "$repo" add docs/guide.rst docs/source.md docs/target.md
  run_expect_failure "unresolved local anchor" "$CHECK" --root "$repo"

  printf '%s\n' '[Target](target.md#real-heading)' > "$repo/docs/source.md"
  git -C "$repo" add docs/source.md
  printf '%s\n' \
    '[Setup](docs/setup.md) [Policy](docs/policy.md) [Broken](docs/missing.bin)' \
    > "$repo/README.md"
  git -C "$repo" add README.md
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"
  pass "local links resolve while dates, versions, commands, and incident prose remain semantically reviewed"

  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md)' > "$repo/README.md"
  printf '%s\n' '# Draft' > "$repo/docs/draft.md"
  run_expect_failure "unclassified: docs/draft.md" "$CHECK" --root "$repo"
  pass "untracked maintained prose cannot bypass audience classification"
}

test_no_mistakes_document_schema() {
  local config="$ROOT/.no-mistakes.yaml"
  assert_grep 'document:' "$config" "trusted Document config is missing"
  assert_grep '  instructions: |' "$config" "Document instructions use an unsupported shape"
  assert_grep 'docs/documentation-audiences.json' "$config" \
    "Document instructions do not point to the audience inventory"
  assert_grep 'complete' "$config" \
    "Document instructions do not require a complete branch-diff review"
  if command -v ruby >/dev/null 2>&1; then
    ruby -e '
      require "yaml"
      data = YAML.safe_load(File.read(ARGV.fetch(0)))
      abort unless data.dig("document", "instructions").is_a?(String)
    ' "$config" || fail ".no-mistakes.yaml did not parse document.instructions"
  fi
  pass "no-mistakes uses the supported trusted document.instructions schema"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_required_pointer_fails
test_local_links_and_no_keyword_heuristic
test_no_mistakes_document_schema
