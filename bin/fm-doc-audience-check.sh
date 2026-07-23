#!/usr/bin/env bash
# fm-doc-audience-check.sh - validate the tracked documentation audience inventory.
#
# Usage:
#   bin/fm-doc-audience-check.sh
#   bin/fm-doc-audience-check.sh --root <repo> [--inventory <path>]
#
# The inventory owns classification and setup routing.
# This check validates structure only and does not keyword-lint prose.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import string
import subprocess
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlsplit

HTML_LINK_RE = re.compile(r"\b(?:href|src)=[\"']([^\"']+)[\"']", re.IGNORECASE)
MARKDOWN_REFERENCE_DEFINITION_RE = re.compile(
    r"^ {0,3}\[[^\]\r\n]+\]:[ \t]*(?:\r\n?|\n)?[ \t]*(?:<([^>\r\n]+)>|(\S+))",
    re.MULTILINE,
)
RST_EMBEDDED_LINK_RE = re.compile(r"`[^`\r\n]*<([^<>\r\n]+)>`__?")
RST_TARGET_RE = re.compile(r"^ {0,3}\.\. _([^:\r\n]+):[ \t]*(.*)$", re.MULTILINE)
RST_ANONYMOUS_TARGET_RE = re.compile(
    r"^ {0,3}(?:\.\. __:|__)[ \t]+(\S.*)$",
    re.MULTILINE,
)
RST_DIRECTIVE_LINK_RE = re.compile(
    r"^ {0,3}\.\. (?:figure|image|include|literalinclude)::[ \t]*(\S.*)$",
    re.MULTILINE | re.IGNORECASE,
)
RST_DOCUMENT_ROLE_RE = re.compile(r":(?:doc|download):`(?:[^`<]*<)?([^`<>]+)>?`")
REQUIRED_TRACKED_PATTERNS = ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]


class CheckError(Exception):
    """One deterministic audience-check failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def git_tracked(root: Path, patterns: list[str]) -> list[str]:
    proc = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
            "--",
            *patterns,
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"git ls-files failed: {detail or 'unknown error'}")
    return sorted(p for p in proc.stdout.decode("utf-8").split("\0") if p)


def load_inventory(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"inventory is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"inventory is unreadable: {exc}")
    if not isinstance(data, dict):
        fail("inventory root must be an object")
    if data.get("version") != 1:
        fail("inventory version must be 1")
    return data


def list_of_strings(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
        fail(f"{label} must be a non-empty string array")
    return value


def markdown_unescape(value: str) -> str:
    result: list[str] = []
    index = 0
    while index < len(value):
        if value[index] == "\\" and index + 1 < len(value) and value[index + 1] in string.punctuation:
            index += 1
        result.append(value[index])
        index += 1
    return "".join(result)


def normalized_link_value(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<") and value.endswith(">"):
        value = value[1:-1].strip()
    if " " in value:
        value = value.split()[0]
    return markdown_unescape(value)


def markdown_link_tail(text: str, index: int) -> int | None:
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text):
        return None
    if text[index] == ")":
        return index + 1
    delimiter = text[index]
    if delimiter not in "\"'(":
        return None
    closing = ")" if delimiter == "(" else delimiter
    index += 1
    while index < len(text):
        if text[index] == "\\" and index + 1 < len(text):
            index += 2
            continue
        if text[index] == closing:
            index += 1
            break
        if text[index] in "\r\n":
            return None
        index += 1
    else:
        return None
    while index < len(text) and text[index].isspace():
        index += 1
    if index < len(text) and text[index] == ")":
        return index + 1
    return None


def markdown_link_destinations(text: str) -> list[str]:
    destinations: list[str] = []
    index = 0
    while index < len(text):
        if text[index] == "\\" and index + 1 < len(text):
            index += 2
            continue
        if text[index] != "[":
            index += 1
            continue
        label_depth = 1
        cursor = index + 1
        while cursor < len(text) and label_depth:
            if text[cursor] == "\\" and cursor + 1 < len(text):
                cursor += 2
                continue
            if text[cursor] == "[":
                label_depth += 1
            elif text[cursor] == "]":
                label_depth -= 1
            cursor += 1
        if label_depth or cursor >= len(text) or text[cursor] != "(":
            index += 1
            continue
        cursor += 1
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        if cursor < len(text) and text[cursor] == "<":
            start = cursor + 1
            cursor = start
            accepted = False
            while cursor < len(text):
                if text[cursor] == "\\" and cursor + 1 < len(text):
                    cursor += 2
                    continue
                if text[cursor] == ">":
                    destination = text[start:cursor]
                    tail_end = markdown_link_tail(text, cursor + 1)
                    if tail_end is not None:
                        destinations.append(destination)
                        index = tail_end
                        accepted = True
                    break
                if text[cursor] in "<\r\n":
                    break
                cursor += 1
            if not accepted:
                index += 1
            continue
        start = cursor
        paren_depth = 0
        accepted = False
        while cursor < len(text):
            if text[cursor] == "\\" and cursor + 1 < len(text):
                cursor += 2
                continue
            if text[cursor] == "(":
                paren_depth += 1
            elif text[cursor] == ")":
                if paren_depth == 0:
                    destinations.append(text[start:cursor])
                    index = cursor + 1
                    accepted = True
                    break
                paren_depth -= 1
            elif text[cursor].isspace() and paren_depth == 0:
                tail_end = markdown_link_tail(text, cursor)
                if tail_end is not None:
                    destinations.append(text[start:cursor])
                    index = tail_end
                    accepted = True
                break
            cursor += 1
        if not accepted:
            index += 1
    return destinations


def markdown_reference_destinations(text: str) -> list[str]:
    return [angle or plain for angle, plain in MARKDOWN_REFERENCE_DEFINITION_RE.findall(text)]


def markdown_without_code(text: str) -> str:
    masked = list(text)

    def mask(start: int, end: int) -> None:
        for position in range(start, end):
            if masked[position] not in "\r\n":
                masked[position] = " "

    def escaped(position: int) -> bool:
        backslashes = 0
        position -= 1
        while position >= 0 and masked[position] == "\\":
            backslashes += 1
            position -= 1
        return backslashes % 2 == 1

    def blockquote_content(line: str) -> tuple[int, int]:
        depth = 0
        position = 0
        while position < len(line):
            marker = position
            spaces = 0
            while marker < len(line) and line[marker] == " " and spaces < 3:
                marker += 1
                spaces += 1
            if marker >= len(line) or line[marker] != ">":
                break
            position = marker + 1
            if position < len(line) and line[position] in " \t":
                position += 1
            depth += 1
        return depth, position

    fence: tuple[str, int, int] | None = None
    indented_depth: int | None = None
    previous_blank = True
    offset = 0
    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        quote_depth, content_start = blockquote_content(content)
        block_content = content[content_start:]
        if fence is not None:
            fence_char, fence_length, fence_depth = fence
            if quote_depth >= fence_depth:
                mask(offset, offset + len(line))
                if quote_depth == fence_depth and re.fullmatch(
                    rf" {{0,3}}{re.escape(fence_char)}{{{fence_length},}}[ \t]*",
                    block_content,
                ):
                    fence = None
                previous_blank = False
                offset += len(line)
                continue
            fence = None
        if indented_depth is not None:
            if not block_content.strip(" \t"):
                mask(offset, offset + len(line))
                previous_blank = True
                offset += len(line)
                continue
            if quote_depth == indented_depth and (
                block_content.startswith("    ") or block_content.startswith("\t")
            ):
                mask(offset, offset + len(line))
                previous_blank = False
                offset += len(line)
                continue
            indented_depth = None
        if not block_content.strip(" \t"):
            previous_blank = True
            offset += len(line)
            continue
        opener = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", block_content)
        if opener is not None:
            marker = opener.group(1)
            info = opener.group(2)
            if marker[0] == "~" or "`" not in info:
                fence = (marker[0], len(marker), quote_depth)
                mask(offset, offset + len(line))
                previous_blank = False
                offset += len(line)
                continue
        if previous_blank and (
            block_content.startswith("    ") or block_content.startswith("\t")
        ):
            indented_depth = quote_depth
            mask(offset, offset + len(line))
            previous_blank = False
            offset += len(line)
            continue
        previous_blank = False
        offset += len(line)

    index = 0
    while index < len(masked):
        if masked[index] != "`" or escaped(index):
            index += 1
            continue
        opening = index
        while index < len(masked) and masked[index] == "`":
            index += 1
        delimiter_length = index - opening
        cursor = index
        closing = None
        while cursor < len(masked):
            if masked[cursor] != "`":
                cursor += 1
                continue
            run_start = cursor
            while cursor < len(masked) and masked[cursor] == "`":
                cursor += 1
            if cursor - run_start == delimiter_length and not escaped(run_start):
                closing = cursor
                break
        if closing is None:
            continue
        mask(opening, closing)
        index = closing

    return "".join(masked)


def rst_without_code(text: str) -> str:
    masked = list(text)

    def mask(start: int, end: int) -> None:
        for position in range(start, end):
            if masked[position] not in "\r\n":
                masked[position] = " "

    literal_base: int | None = None
    offset = 0
    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        expanded = content.expandtabs(8)
        indentation = len(expanded) - len(expanded.lstrip(" "))
        if literal_base is not None:
            if not content.strip():
                mask(offset, offset + len(line))
                offset += len(line)
                continue
            if indentation > literal_base:
                mask(offset, offset + len(line))
                offset += len(line)
                continue
            literal_base = None
        literal_directive = re.match(
            r"^( {0,3})\.\. (?:code|code-block|sourcecode|raw|math)::",
            content,
            re.IGNORECASE,
        )
        directive = re.match(r"^ {0,3}\.\. [A-Za-z0-9_-]+::", content)
        if literal_directive is not None:
            literal_base = len(literal_directive.group(1))
            mask(offset, offset + len(line))
        elif directive is None and content.rstrip().endswith("::"):
            literal_base = indentation
        offset += len(line)

    prose = "".join(masked)
    masked = list(prose)
    for match in re.finditer(r"``.*?``", prose, re.DOTALL):
        mask(match.start(), match.end())
    return "".join(masked)


def resolve_local_target(root: Path, source: Path, raw: str) -> Path | None:
    split = urlsplit(normalized_link_value(raw))
    if split.scheme or split.netloc:
        return None
    if not split.path:
        return source.resolve(strict=False) if split.fragment else None
    decoded = unquote(split.path)
    if decoded.startswith("/"):
        fail(f"absolute local link in {source.relative_to(root)}: {raw}")
    target = (source.parent / decoded).resolve(strict=False)
    try:
        target.relative_to(root.resolve())
    except ValueError:
        fail(f"local link escapes repository in {source.relative_to(root)}: {raw}")
    return target


def read_prose(root: Path, source: Path) -> str:
    try:
        return source.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read prose surface {source.relative_to(root)}: {exc}")


def rst_link_destinations(text: str) -> list[str]:
    destinations = RST_EMBEDDED_LINK_RE.findall(text)
    destinations.extend(target for _, target in RST_TARGET_RE.findall(text) if target)
    destinations.extend(RST_ANONYMOUS_TARGET_RE.findall(text))
    destinations.extend(RST_DIRECTIVE_LINK_RE.findall(text))
    destinations.extend(RST_DOCUMENT_ROLE_RE.findall(text))
    return [target for target in destinations if not target.rstrip().endswith("_")]


def local_links(root: Path, source: Path) -> list[tuple[str, Path]]:
    text = read_prose(root, source)
    if source.suffix.lower() == ".rst":
        prose = rst_without_code(text)
        raw_links = rst_link_destinations(prose)
    else:
        prose = markdown_without_code(text)
        raw_links = (
            markdown_link_destinations(prose)
            + markdown_reference_destinations(prose)
            + HTML_LINK_RE.findall(prose)
        )
    result: list[tuple[str, Path]] = []
    for raw in raw_links:
        target = resolve_local_target(root, source, raw)
        if target is not None:
            result.append((raw, target))
    return result


def github_heading_slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("`", "").strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return re.sub(r"\s", "-", value)


def markdown_anchors(root: Path, path: Path) -> set[str]:
    anchors: set[str] = set()
    counts: Counter[str] = Counter()
    prose = markdown_without_code(read_prose(root, path))
    for line in prose.splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if match:
            base = github_heading_slug(match.group(1))
            if base:
                count = counts[base]
                anchors.add(base if count == 0 else f"{base}-{count}")
                counts[base] += 1
        for explicit in re.findall(r"<(?:a|span)\s+(?:name|id)=[\"']([^\"']+)[\"']", line, re.IGNORECASE):
            anchors.add(explicit)
    return anchors


def rst_heading_slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def rst_anchors(root: Path, path: Path) -> set[str]:
    prose = rst_without_code(read_prose(root, path))
    anchors = {
        rst_heading_slug(name)
        for name, _ in RST_TARGET_RE.findall(prose)
        if rst_heading_slug(name)
    }
    lines = prose.splitlines()
    adornment = re.compile(r"^([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])\1{2,}\s*$")
    for index in range(len(lines) - 1):
        title = lines[index].strip()
        underline = lines[index + 1].strip()
        if title and adornment.fullmatch(underline) and len(underline) >= len(title):
            slug = rst_heading_slug(title)
            if slug:
                anchors.add(slug)
    return anchors


def document_anchors(root: Path, path: Path) -> set[str]:
    if path.suffix.lower() == ".rst":
        return rst_anchors(root, path)
    return markdown_anchors(root, path)


def validate(root: Path, inventory_path: Path) -> tuple[int, int]:
    data = load_inventory(inventory_path)
    scope = data.get("scope")
    if not isinstance(scope, dict):
        fail("scope must be an object")
    patterns = list_of_strings(scope.get("trackedPatterns"), "scope.trackedPatterns")
    if patterns != REQUIRED_TRACKED_PATTERNS:
        fail("scope.trackedPatterns must match the fixed maintained-prose scope")
    audiences = set(list_of_strings(data.get("allowedAudiences"), "allowedAudiences"))
    setup_audiences = set(list_of_strings(data.get("setupAudiences"), "setupAudiences"))
    if not setup_audiences <= audiences:
        fail("setupAudiences contains an audience outside allowedAudiences")

    surfaces = data.get("surfaces")
    if not isinstance(surfaces, list):
        fail("surfaces must be an array")
    paths: list[str] = []
    classifications: dict[str, str] = {}
    for index, entry in enumerate(surfaces):
        if not isinstance(entry, dict):
            fail(f"surfaces[{index}] must be an object")
        path = entry.get("path")
        audience = entry.get("audience")
        if not isinstance(path, str) or not path:
            fail(f"surfaces[{index}].path must be a non-empty string")
        if audience not in audiences:
            fail(f"{path}: unsupported audience {audience!r}")
        paths.append(path)
        classifications[path] = audience

    duplicates = sorted(path for path, count in Counter(paths).items() if count != 1)
    if duplicates:
        fail("surfaces classified more than once: " + ", ".join(duplicates))

    tracked = set(git_tracked(root, patterns))
    classified = set(paths)
    missing = sorted(tracked - classified)
    extra = sorted(classified - tracked)
    if missing or extra:
        details = []
        if missing:
            details.append("unclassified: " + ", ".join(missing))
        if extra:
            details.append("not tracked/in scope: " + ", ".join(extra))
        fail("; ".join(details))

    readme_path = root / "README.md"
    readme_targets = {
        os.path.relpath(target, root).replace(os.sep, "/")
        for _, target in local_links(root, readme_path)
    }
    setup_targets = list_of_strings(data.get("readmeSetupTargets"), "readmeSetupTargets")
    for target in setup_targets:
        if target not in readme_targets:
            fail(f"README setup target is not linked from README.md: {target}")
        if classifications.get(target) not in setup_audiences:
            fail(
                f"README setup target {target} has disallowed audience "
                f"{classifications.get(target)!r}"
            )

    pointers = data.get("requiredOwnerPointers")
    if not isinstance(pointers, list) or not pointers:
        fail("requiredOwnerPointers must be a non-empty array")
    for index, pointer in enumerate(pointers):
        if not isinstance(pointer, dict):
            fail(f"requiredOwnerPointers[{index}] must be an object")
        source = pointer.get("source")
        target = pointer.get("target")
        if not isinstance(source, str) or not isinstance(target, str) or not source or not target:
            fail(f"requiredOwnerPointers[{index}] needs non-empty source and target")
        source_path = root / source
        target_path = root / target
        if not source_path.exists():
            fail(f"owner-pointer source is missing: {source}")
        if not target_path.exists():
            fail(f"owner-pointer target is missing: {target}")
        try:
            source_text = source_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"owner-pointer source is unreadable {source}: {exc}")
        linked_targets: set[str] = set()
        if source_path.suffix.lower() in {".md", ".mdx", ".rst"}:
            linked_targets = {
                os.path.relpath(linked, root).replace(os.sep, "/")
                for _, linked in local_links(root, source_path)
            }
        if target not in source_text and target not in linked_targets:
            fail(f"required owner pointer missing: {source} -> {target}")

    checked_links = 0
    anchor_cache: dict[Path, set[str]] = {}
    for path in sorted(tracked):
        if Path(path).suffix.lower() not in {".md", ".mdx", ".rst"}:
            continue
        source = root / path
        for raw, target in local_links(root, source):
            checked_links += 1
            if not target.exists():
                fail(f"unresolved local link in {path}: {raw}")
            fragment = unquote(urlsplit(normalized_link_value(raw)).fragment)
            if fragment and target.is_file() and target.suffix.lower() in {".md", ".mdx", ".rst"}:
                anchors = anchor_cache.setdefault(target, document_anchors(root, target))
                if fragment not in anchors:
                    fail(f"unresolved local anchor in {path}: {raw}")

    return len(tracked), checked_links


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Firstmate documentation audiences and local links.")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--inventory", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    inventory_path = args.inventory or (root / "docs/documentation-audiences.json")
    if not inventory_path.is_absolute():
        inventory_path = root / inventory_path
    try:
        surfaces, links = validate(root, inventory_path)
    except CheckError as exc:
        print(f"fm-doc-audience-check: {exc}", file=sys.stderr)
        return 1
    print(f"fm-doc-audience-check: ok surfaces={surfaces} local_links={links}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
