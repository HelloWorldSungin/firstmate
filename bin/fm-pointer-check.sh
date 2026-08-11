#!/usr/bin/env bash
# fm-pointer-check.sh - resolve CROSS-SYSTEM pointers in prose and report each
# one as ok, broken, or could-not-verify.
#
# Usage:
#   bin/fm-pointer-check.sh                       # tracked Markdown in this repo
#   bin/fm-pointer-check.sh <path>...             # explicit files or directories,
#                                                 # inside or outside this repo
#   bin/fm-pointer-check.sh --verbose             # print every pointer, not just
#                                                 # the ones that are not ok
#   bin/fm-pointer-check.sh --json                # machine-readable results
#   bin/fm-pointer-check.sh --require-credential  # refuse to "pass" having
#                                                 # verified nothing
#   bin/fm-pointer-check.sh --root <repo>         # repository whose tracked
#                                                 # Markdown is the default scan
#
# Scope, and the one-owner split with the sibling check:
#   This script owns CROSS-SYSTEM pointers - an http(s) URL leaving the file's
#   own repository. bin/fm-doc-audience-check.sh owns IN-REPO pointers: local
#   Markdown links, their anchors, and the declared source -> target owner
#   pointers in docs/documentation-audiences.json, which is how a pointer living
#   in a code comment gets pinned. Neither check re-implements the other's class.
#   docs/one-owner.md is the convention both of them serve.
#
# Verdicts, and why there are three rather than two:
#   ok          the target resolved.
#   broken      the target provably does not resolve.
#   unverified  the target could NOT be resolved either way. This is its own
#               outcome on purpose. A private repository answers an
#               unauthenticated request with 404, exactly as a repository that
#               never existed does, so a two-verdict check must call one of
#               those two cases wrong. This one refuses to guess.
#   skipped     no adapter claims the pointer (a non-GitHub host, a placeholder
#               URL, a GitHub surface that is not a repository pointer). Never
#               counted as verified.
#
# How a GitHub pointer is resolved, most specific evidence first:
#   1. No usable credential                -> unverified (nothing was checked).
#   2. Repository visible to the credential:
#        blob/tree path present            -> ok
#        blob/tree path absent             -> broken
#        issue or pull request present     -> ok / absent -> broken
#        any other repository surface      -> ok at repository scope only
#   3. Repository not visible: look the OWNER account up. Account existence is
#      public even when every repository under it is private, so:
#        owner does not exist              -> broken   (definitive)
#        owner exists, repository unseen   -> unverified (private or absent,
#                                             and this credential cannot tell
#                                             those apart - so neither will we)
#   4. Rate limit, forbidden, transport failure -> unverified with the reason.
#
# Exit status:
#   0  no broken pointer (unverified and skipped never fail the run)
#   1  at least one broken pointer
#   2  usage error, or --require-credential with no usable credential
#
# Environment:
#   FM_POINTER_CHECK_GH  gh binary to resolve GitHub pointers with (default gh).
#                        Tests point this at a stub so the portable suite never
#                        touches the network.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_POINTER_CHECK_DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export FM_POINTER_CHECK_DEFAULT_ROOT
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HTML_LINK_RE = re.compile(r"\b(?:href|src)=[\"']([^\"']+)[\"']", re.IGNORECASE)
BARE_URL_RE = re.compile(r"https?://[^\s<>\"'`)\]}]+")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
MARKDOWN_SUFFIXES = {".md", ".mdx"}

# A URL carrying any of these is a template or an illustration, not a pointer a
# reader can follow. Skipped rather than reported, because there is nothing to
# resolve and a "broken" verdict on a documented placeholder is noise that
# teaches contributors to ignore the check.
PLACEHOLDER_MARKERS = ("<", ">", "{", "}", "$", "...", "%s", "*")

# github.com paths whose first segment is a site surface rather than an account.
# A project board, a marketplace listing, or a settings page is not a repository
# pointer, and this check does not claim to resolve one.
GITHUB_RESERVED_ROOTS = {
    "about", "apps", "collections", "contact", "customer-stories", "enterprise",
    "events", "explore", "features", "join", "login", "marketplace", "new",
    "notifications", "orgs", "pricing", "pulls", "readme", "search", "security",
    "sessions", "settings", "site", "sponsors", "topics", "trending", "users",
}


class UsageError(Exception):
    """A caller mistake, reported without pretending any pointer was checked."""


class Pointer:
    def __init__(self, source: str, line: int, url: str) -> None:
        self.source = source
        self.line = line
        self.url = url
        self.verdict = "skipped"
        self.reason = ""
        self.detail = ""
        self.scope = ""

    def decide(self, verdict: str, reason: str, detail: str = "", scope: str = "") -> None:
        self.verdict = verdict
        self.reason = reason
        self.detail = detail
        self.scope = scope

    def as_dict(self) -> dict:
        return {
            "source": self.source,
            "line": self.line,
            "url": self.url,
            "verdict": self.verdict,
            "reason": self.reason,
            "detail": self.detail,
            "scope": self.scope,
        }

    def render(self) -> str:
        head = f"{self.verdict:<10} {self.source}:{self.line}  {self.url}  {self.reason}"
        if self.scope:
            head += f" [scope={self.scope}]"
        if self.detail:
            head += f"\n{'':<10} {self.detail}"
        return head


def normalized_link_value(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<") and value.endswith(">"):
        value = value[1:-1].strip()
    if " " in value:
        value = value.split()[0]
    return value


def trimmed_url(raw: str) -> str:
    # Prose punctuation that cannot be part of the target: a sentence-final full
    # stop, a comma, a closing quote left by the surrounding text.
    return raw.rstrip(".,;:!?'\"")


def is_placeholder(url: str) -> bool:
    return any(marker in url for marker in PLACEHOLDER_MARKERS)


def strip_fenced_blocks(text: str) -> str:
    """Blank out fenced code blocks, keeping line numbers intact.

    Anything inside a fence is an illustration of a wire format - this
    repository's own docs and tests are full of deliberately fictional URLs, and
    a verification record quotes broken ones on purpose. Prose outside a fence is
    where a pointer a reader is invited to follow lives. That is the line this
    function draws, and it is why the check stays quiet enough to trust. It
    applies to link syntax as much as to bare URLs: a Markdown link inside a
    fence is still an example.
    """
    kept: list[str] = []
    fence: str | None = None
    for line in text.splitlines():
        match = FENCE_RE.match(line)
        if match:
            if fence is None:
                fence = match.group(1)
            elif line.strip().startswith(fence):
                fence = None
            kept.append("")
            continue
        kept.append("" if fence is not None else line)
    return "\n".join(kept)


def line_of(text: str, needle: str, used: dict[str, int]) -> int:
    start = used.get(needle, 0)
    index = text.find(needle, start)
    if index < 0:
        index = text.find(needle)
        if index < 0:
            return 1
    used[needle] = index + 1
    return text.count("\n", 0, index) + 1


def extract_pointers(display: str, text: str, is_markdown: bool) -> list[Pointer]:
    found: list[str] = []
    # Link syntax survives inline code stripping on purpose: [`some/path`](url)
    # is the ordinary way a pointer names its target, and the URL sits outside
    # the backticks. Only fences are removed before this pass.
    linkable = strip_fenced_blocks(text) if is_markdown else text
    for raw in MARKDOWN_LINK_RE.findall(linkable) + HTML_LINK_RE.findall(linkable):
        found.append(normalized_link_value(raw))
    body = INLINE_CODE_RE.sub(" ", linkable) if is_markdown else linkable
    for match in BARE_URL_RE.finditer(body):
        # The bare-URL pattern stops at a placeholder delimiter, so a template
        # like https://github.com/<owner>/<repo> would otherwise survive as the
        # truncated prefix https://github.com/ and be reported as a real target.
        # Look at what the match ran into before accepting it.
        following = body[match.end():match.end() + 1]
        if following in {"<", "{", "$", "%"}:
            continue
        found.append(match.group(0))

    pointers: list[Pointer] = []
    seen: set[str] = set()
    used: dict[str, int] = {}
    for raw in found:
        url = trimmed_url(normalized_link_value(raw))
        if not url.lower().startswith(("http://", "https://")):
            continue
        if url in seen:
            continue
        seen.add(url)
        pointers.append(Pointer(display, line_of(text, url, used), url))
    return pointers


class GitHubResolver:
    """Resolve github.com pointers through an authenticated API, or say so."""

    def __init__(self, gh_bin: str) -> None:
        self.gh_bin = gh_bin
        self.credential = "unknown"
        self.credential_detail = ""
        self.repo_cache: dict[tuple[str, str], tuple[int | None, str]] = {}
        self.owner_cache: dict[str, tuple[int | None, str]] = {}
        self.calls = 0

    def api(self, endpoint: str) -> tuple[int | None, str]:
        """Return (http_status, detail). A None status means no answer at all."""
        self.calls += 1
        try:
            proc = subprocess.run(
                [self.gh_bin, "api", "-i", endpoint],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
            )
        except FileNotFoundError:
            return None, f"{self.gh_bin} is not installed"
        except subprocess.TimeoutExpired:
            return None, f"timed out calling {self.gh_bin} api {endpoint}"
        head = proc.stdout.decode("utf-8", "replace").splitlines()
        status = None
        if head:
            match = re.match(r"HTTP/[\d.]+\s+(\d{3})", head[0])
            if match:
                status = int(match.group(1))
        detail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        return status, (detail[0] if detail else "")

    def probe_credential(self) -> None:
        status, detail = self.api("user")
        if status == 200:
            self.credential = "authenticated"
            self.credential_detail = ""
        elif status is None:
            self.credential = "none"
            self.credential_detail = detail or "no answer from the GitHub API"
        else:
            # A credential that answers but cannot be used - expired, throttled,
            # or scoped away - is not the same as having none, and saying "no
            # credential" would send the reader to the wrong fix.
            self.credential = "unusable"
            self.credential_detail = detail or f"credential probe returned HTTP {status}"

    def repo(self, owner: str, repo: str) -> tuple[int | None, str]:
        key = (owner.lower(), repo.lower())
        if key not in self.repo_cache:
            self.repo_cache[key] = self.api(f"repos/{owner}/{repo}")
        return self.repo_cache[key]

    def owner(self, owner: str) -> tuple[int | None, str]:
        key = owner.lower()
        if key not in self.owner_cache:
            # /users/<name> answers for organizations too, and account existence
            # is public information even when every repository is private. That
            # is what makes a 404 here evidence rather than a guess.
            self.owner_cache[key] = self.api(f"users/{owner}")
        return self.owner_cache[key]

    def resolve(self, pointer: Pointer) -> None:
        split = urlsplit(pointer.url)
        host = split.netloc.lower()
        if host not in {"github.com", "www.github.com"}:
            pointer.decide("skipped", "no-adapter", f"{host or 'unknown host'} has no resolver in this check")
            return

        segments = [unquote(s) for s in split.path.strip("/").split("/") if s]
        if not segments:
            pointer.decide("skipped", "not-a-repository-pointer", "the site root carries no target")
            return
        if segments[0].lower() in GITHUB_RESERVED_ROOTS:
            pointer.decide(
                "skipped",
                "not-a-repository-pointer",
                f"/{segments[0]} is a site surface, not an account or repository",
            )
            return

        if self.credential != "authenticated":
            pointer.decide(
                "unverified",
                "no-credential" if self.credential == "none" else "credential-unusable",
                self.credential_detail
                or "no usable GitHub credential, so nothing about this pointer was checked",
            )
            return

        owner = segments[0]
        if len(segments) == 1:
            status, detail = self.owner(owner)
            if status == 200:
                pointer.decide("ok", "owner-resolved", scope="account")
            elif status == 404:
                pointer.decide("broken", "owner-not-found", f"github.com/{owner} does not exist")
            else:
                self.inconclusive(pointer, status, detail)
            return

        repo = segments[1]
        status, detail = self.repo(owner, repo)
        if status == 404:
            owner_status, owner_detail = self.owner(owner)
            if owner_status == 404:
                pointer.decide("broken", "owner-not-found", f"github.com/{owner} does not exist")
            elif owner_status == 200:
                pointer.decide(
                    "unverified",
                    "repo-not-visible",
                    f"github.com/{owner} exists but this credential cannot see {owner}/{repo}: "
                    "private and inaccessible is indistinguishable from absent, so this is not "
                    "evidence either way",
                )
            else:
                self.inconclusive(pointer, owner_status, owner_detail)
            return
        if status != 200:
            self.inconclusive(pointer, status, detail)
            return

        self.resolve_inside_repo(pointer, owner, repo, segments, split.fragment)

    def resolve_inside_repo(
        self, pointer: Pointer, owner: str, repo: str, segments: list[str], fragment: str
    ) -> None:
        if len(segments) == 2:
            pointer.decide("ok", "repo-resolved", scope="repository")
            return

        kind = segments[2].lower()
        rest = segments[3:]

        if kind in {"blob", "tree", "raw"} and len(rest) == 1:
            # A bare ref with no path below it: a branch, tag, or commit.
            ref = rest[0]
            status, detail = self.api(f"repos/{owner}/{repo}/commits/{ref}")
            if status == 200:
                pointer.decide("ok", "ref-resolved", scope="ref")
            elif status in {404, 422}:
                pointer.decide(
                    "broken",
                    "ref-not-found",
                    f"the repository is visible, but it has no ref {ref}",
                )
            else:
                self.inconclusive(pointer, status, detail)
            return

        if kind in {"blob", "tree", "raw"} and len(rest) >= 2:
            ref, path = rest[0], "/".join(rest[1:])
            status, detail = self.api(f"repos/{owner}/{repo}/contents/{path}?ref={ref}")
            if status == 200:
                scope = "file" if not fragment else "file (fragment not checked)"
                pointer.decide("ok", "path-resolved", scope=scope)
            elif status == 404:
                pointer.decide(
                    "broken",
                    "ref-or-path-not-found",
                    f"the repository is visible, but {path} at ref {ref} is not in it",
                )
            else:
                self.inconclusive(pointer, status, detail)
            return

        if kind in {"issues", "pull"} and rest and rest[0].isdigit():
            number = rest[0]
            # One endpoint answers for both: a pull request is an issue here.
            status, detail = self.api(f"repos/{owner}/{repo}/issues/{number}")
            if status == 200:
                pointer.decide("ok", "issue-resolved", scope="issue")
            elif status == 404:
                pointer.decide(
                    "broken",
                    "issue-not-found",
                    f"the repository is visible, but it has no #{number}",
                )
            else:
                self.inconclusive(pointer, status, detail)
            return

        if kind == "actions" and len(rest) >= 2 and rest[0] == "runs" and rest[1].isdigit():
            status, detail = self.api(f"repos/{owner}/{repo}/actions/runs/{rest[1]}")
            if status == 200:
                pointer.decide("ok", "run-resolved", scope="workflow run")
            elif status == 404:
                pointer.decide(
                    "broken",
                    "run-not-found",
                    f"the repository is visible, but it has no workflow run {rest[1]}",
                )
            else:
                self.inconclusive(pointer, status, detail)
            return

        # Some other surface of a repository this credential can see. The
        # repository resolved, so say exactly that and no more.
        pointer.decide("ok", "repo-resolved", scope="repository")

    def inconclusive(self, pointer: Pointer, status: int | None, detail: str) -> None:
        if status is None:
            pointer.decide("unverified", "no-answer", detail or "the GitHub API did not answer")
        elif status in {403, 429}:
            pointer.decide(
                "unverified",
                "rate-limited-or-forbidden",
                detail or f"HTTP {status} from the GitHub API",
            )
        else:
            pointer.decide("unverified", "unexpected-status", detail or f"HTTP {status} from the GitHub API")


def tracked_markdown(root: Path) -> list[Path]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "*.md", "*.mdx"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        raise UsageError(f"git ls-files failed in {root}: {detail or 'unknown error'}")
    return sorted(root / p for p in proc.stdout.decode("utf-8").split("\0") if p)


def collect_files(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(sorted(p for p in path.rglob("*") if p.is_file()))
        elif path.is_file():
            files.append(path)
        else:
            raise UsageError(f"no such file or directory: {path}")
    return files


def display_path(path: Path, root: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="fm-pointer-check.sh",
        description="Resolve cross-system pointers and separate broken from could-not-verify.",
    )
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument("--root", type=Path, default=Path(os.environ.get("FM_POINTER_CHECK_DEFAULT_ROOT", ".")))
    parser.add_argument("--verbose", action="store_true", help="print every pointer, not only the ones that are not ok")
    parser.add_argument("--json", action="store_true", help="emit results as JSON")
    parser.add_argument(
        "--require-credential",
        action="store_true",
        help="exit 2 when no credential is available, instead of passing having verified nothing",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    try:
        files = collect_files(args.paths) if args.paths else tracked_markdown(root)
    except UsageError as exc:
        print(f"fm-pointer-check: {exc}", file=sys.stderr)
        return 2

    pointers: list[Pointer] = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            # A binary or unreadable file carries no prose pointer to resolve.
            continue
        found = extract_pointers(display_path(path, root), text, path.suffix.lower() in MARKDOWN_SUFFIXES)
        pointers.extend(p for p in found if not is_placeholder(p.url))

    resolver = GitHubResolver(os.environ.get("FM_POINTER_CHECK_GH", "gh"))
    if pointers:
        resolver.probe_credential()
    for pointer in pointers:
        resolver.resolve(pointer)

    counts = {"ok": 0, "broken": 0, "unverified": 0, "skipped": 0}
    for pointer in pointers:
        counts[pointer.verdict] += 1

    credential = resolver.credential if pointers else "not-probed"
    summary = (
        f"fm-pointer-check: checked={len(pointers)} ok={counts['ok']} broken={counts['broken']} "
        f"unverified={counts['unverified']} skipped={counts['skipped']} "
        f"files={len(files)} credential={credential}"
    )

    if args.json:
        print(json.dumps(
            {
                "credential": credential,
                "credential_detail": resolver.credential_detail,
                "counts": counts,
                "files": len(files),
                "api_calls": resolver.calls,
                "pointers": [p.as_dict() for p in pointers],
            },
            indent=2,
        ))
    else:
        for pointer in pointers:
            if args.verbose or pointer.verdict in {"broken", "unverified"}:
                print(pointer.render())
        print(summary)
        if counts["unverified"]:
            print(
                "fm-pointer-check: 'unverified' is not a pass and not a failure - "
                "those pointers were not resolved either way.",
            )

    if args.require_credential and credential not in {"authenticated", "not-probed"}:
        print(
            "fm-pointer-check: --require-credential was given but no usable GitHub credential is "
            f"available ({resolver.credential_detail or 'unknown reason'}).",
            file=sys.stderr,
        )
        return 2
    return 1 if counts["broken"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except UsageError as exc:
        print(f"fm-pointer-check: {exc}", file=sys.stderr)
        sys.exit(2)
PY
