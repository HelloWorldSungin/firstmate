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
# Verdicts, and why there are four rather than two:
#   ok          the target resolved.
#   broken      the target provably does not resolve.
#   unverified  the target could NOT be resolved either way. This is its own
#               outcome on purpose. A private repository answers an
#               unauthenticated request with 404, exactly as a repository that
#               never existed does, so a two-verdict check must call one of
#               those two cases wrong. This one refuses to guess.
#   skipped     no adapter claims the pointer (a non-GitHub host, a placeholder
#               URL, a GitHub surface that is not a repository pointer). Never
#               counted as verified, and always printed with its reason: a
#               pointer that disappears without a verdict is the failure this
#               whole check exists to prevent.
#
# How a GitHub pointer is resolved, most specific evidence first:
#   1. No usable credential                -> unverified (nothing was checked).
#   2. Repository visible to the credential:
#        blob/tree path present            -> ok
#        blob/tree path absent at a ref
#          this credential can see         -> broken
#        no reading of the URL names a ref
#          this credential can see         -> unverified (a branch name may
#                                             contain slashes, so which part of
#                                             the URL is the ref is a question
#                                             only the API can settle)
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
# How the credential is probed, and why not with GET /user:
#   The probe has to be answerable by every credential shape this check runs
#   under, including the GitHub App installation token CI passes as GH_TOKEN.
#   GET /user is user-context and an installation token is refused there, so
#   probing it would report a perfectly usable credential as unusable. GET
#   /rate_limit answers for any credential, does not consume the limit it
#   reports, and discloses the one fact the probe needs: the unauthenticated
#   ceiling is 60 requests an hour and no authenticated credential is that low.
#   Credential states: authenticated, none, unusable (answered and rejected),
#   throttled (the probe itself was rate limited, which resolves nothing and -
#   like every other throttled lookup - fails nothing).
#
# Exit status:
#   0  no broken pointer (unverified and skipped never fail the run)
#   1  at least one broken pointer
#   2  usage error, or --require-credential with no usable credential or with
#      nothing to resolve
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
from typing import NamedTuple
from urllib.parse import quote, unquote, urlsplit

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HTML_LINK_RE = re.compile(r"\b(?:href|src)=[\"']([^\"']+)[\"']", re.IGNORECASE)
BARE_URL_RE = re.compile(r"https?://[^\s<>\"'`)\]}]+")
# The same URL, allowed to run through placeholder delimiters. Used only to
# recover the full text of a template the pattern above stopped short of, so the
# template is reported as itself rather than as the prefix it was cut down to.
TEMPLATE_URL_RE = re.compile(r"https?://[^\s\"'`)\]]+")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
MARKDOWN_SUFFIXES = {".md", ".mdx"}

# A URL carrying any of these is a template or an illustration, not a pointer a
# reader can follow. Reported as skipped with a reason rather than resolved:
# there is nothing to resolve, and a "broken" verdict on a documented
# placeholder is noise that teaches contributors to ignore the check. It is
# reported rather than dropped because these markers are broad enough to catch a
# real URL, and a pointer that vanishes silently is worse than one refused out
# loud.
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

# An unauthenticated client gets 60 core requests an hour. Every authenticated
# credential shape - personal token, OAuth token, GitHub App installation token -
# is well above it, which is what makes this number a usable authentication test.
UNAUTHENTICATED_CORE_LIMIT = 60

# Why a pointer went unresolved when the credential itself is the reason. The
# distinctions matter because they send a reader to different fixes.
CREDENTIAL_REASON = {
    "none": "no-credential",
    "unusable": "credential-unusable",
    "throttled": "rate-limited-or-forbidden",
    "unknown": "credential-not-probed",
}


class UsageError(Exception):
    """A caller mistake, reported without pretending any pointer was checked."""


class Answer(NamedTuple):
    """One API response. A status of None means no answer at all."""

    status: int | None
    detail: str
    headers: dict
    body: str


class Pointer:
    def __init__(self, source: str, line: int, url: str) -> None:
        self.source = source
        self.line = line
        self.url = url
        self.verdict = "skipped"
        self.reason = ""
        self.detail = ""
        self.scope = ""
        self.resolvable = True

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
        # Take the whole template instead, so it is refused as the template it is
        # rather than resolved as the prefix it is not.
        if body[match.end():match.end() + 1] in {"<", "{", "$", "%"}:
            wider = TEMPLATE_URL_RE.match(body, match.start())
            found.append(wider.group(0) if wider else match.group(0))
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
        pointer = Pointer(display, line_of(text, url, used), url)
        if is_placeholder(url):
            pointer.resolvable = False
            pointer.decide(
                "skipped",
                "template",
                "a placeholder or illustration, so there is no target to resolve",
            )
        pointers.append(pointer)
    return pointers


def core_rate_limit(answer: Answer) -> int | None:
    """The core requests-per-hour ceiling this client is subject to, if stated."""
    if answer.headers.get("x-ratelimit-resource", "core").lower() == "core":
        raw = answer.headers.get("x-ratelimit-limit", "")
        if raw.isdigit():
            return int(raw)
    try:
        data = json.loads(answer.body)
    except (TypeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    limit = data.get("resources", {}).get("core", {}).get("limit")
    return limit if isinstance(limit, int) else None


class GitHubResolver:
    """Resolve github.com pointers through an authenticated API, or say so."""

    def __init__(self, gh_bin: str) -> None:
        self.gh_bin = gh_bin
        self.credential = "unknown"
        self.credential_detail = ""
        self.cache: dict[str, Answer] = {}
        self.calls = 0

    def api(self, endpoint: str) -> Answer:
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
            return Answer(None, f"{self.gh_bin} is not installed", {}, "")
        except subprocess.TimeoutExpired:
            return Answer(None, f"timed out calling {self.gh_bin} api {endpoint}", {}, "")
        out = proc.stdout.decode("utf-8", "replace").replace("\r\n", "\n")
        head, _, body = out.partition("\n\n")
        lines = head.splitlines()
        status = None
        headers: dict[str, str] = {}
        if lines:
            match = re.match(r"HTTP/[\d.]+\s+(\d{3})", lines[0])
            if match:
                status = int(match.group(1))
            for line in lines[1:]:
                name, sep, value = line.partition(":")
                if sep:
                    headers[name.strip().lower()] = value.strip()
        detail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        return Answer(status, detail[0] if detail else "", headers, body)

    def cached(self, endpoint: str) -> Answer:
        if endpoint not in self.cache:
            self.cache[endpoint] = self.api(endpoint)
        return self.cache[endpoint]

    def probe_credential(self) -> None:
        answer = self.cached("rate_limit")
        if answer.status == 200:
            limit = core_rate_limit(answer)
            if limit is not None and limit <= UNAUTHENTICATED_CORE_LIMIT:
                self.credential = "none"
                self.credential_detail = (
                    f"the GitHub API answered with the unauthenticated ceiling of {limit} "
                    "requests an hour, so this client is carrying no credential"
                )
            else:
                self.credential = "authenticated"
                self.credential_detail = ""
        elif answer.status is None:
            self.credential = "none"
            self.credential_detail = answer.detail or "no answer from the GitHub API"
        elif answer.status in {403, 429}:
            # Throttled before a single pointer was looked at. The credential is
            # not faulty and throttling is never evidence about a target, so this
            # resolves nothing and - like any other throttled lookup - fails
            # nothing.
            self.credential = "throttled"
            self.credential_detail = (
                answer.detail or f"the credential probe was rate limited (HTTP {answer.status})"
            )
        else:
            # A credential that answers but cannot be used - expired, or scoped
            # away - is not the same as having none, and saying "no credential"
            # would send the reader to the wrong fix.
            self.credential = "unusable"
            self.credential_detail = (
                answer.detail or f"the credential probe returned HTTP {answer.status}"
            )

    def repo(self, owner: str, repo: str) -> Answer:
        return self.cached(f"repos/{owner}/{repo}")

    def owner(self, owner: str) -> Answer:
        # /users/<name> answers for organizations too, and account existence is
        # public information even when every repository is private. That is what
        # makes a 404 here evidence rather than a guess.
        return self.cached(f"users/{quote(owner, safe='')}")

    def contents(self, owner: str, repo: str, path: str, ref: str) -> Answer:
        return self.cached(
            f"repos/{owner}/{repo}/contents/{quote(path, safe='/')}?ref={quote(ref, safe='/')}"
        )

    def ref_exists(self, owner: str, repo: str, ref: str) -> Answer:
        # The ref travels in a query parameter rather than in the path: a branch
        # name containing a slash is the norm here, and in the path form it would
        # be indistinguishable from extra route segments.
        return self.cached(
            f"repos/{owner}/{repo}/commits?sha={quote(ref, safe='/')}&per_page=1"
        )

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
                CREDENTIAL_REASON.get(self.credential, "credential-unusable"),
                self.credential_detail
                or "no usable GitHub credential, so nothing about this pointer was checked",
            )
            return

        owner = segments[0]
        if len(segments) == 1:
            answer = self.owner(owner)
            if answer.status == 200:
                pointer.decide("ok", "owner-resolved", scope="account")
            elif answer.status == 404:
                pointer.decide("broken", "owner-not-found", f"github.com/{owner} does not exist")
            else:
                self.inconclusive(pointer, answer)
            return

        repo = segments[1]
        answer = self.repo(owner, repo)
        if answer.status == 404:
            owner_answer = self.owner(owner)
            if owner_answer.status == 404:
                pointer.decide("broken", "owner-not-found", f"github.com/{owner} does not exist")
            elif owner_answer.status == 200:
                pointer.decide(
                    "unverified",
                    "repo-not-visible",
                    f"github.com/{owner} exists but this credential cannot see {owner}/{repo}: "
                    "private and inaccessible is indistinguishable from absent, so this is not "
                    "evidence either way",
                )
            else:
                self.inconclusive(pointer, owner_answer)
            return
        if answer.status != 200:
            self.inconclusive(pointer, answer)
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
            # A bare ref with no path below it, and only one reading of it: a
            # branch, tag, or commit that either exists or does not.
            ref = rest[0]
            answer = self.ref_exists(owner, repo, ref)
            if answer.status == 200:
                pointer.decide("ok", "ref-resolved", scope="ref")
            elif answer.status in {404, 422}:
                pointer.decide(
                    "broken",
                    "ref-not-found",
                    f"the repository is visible, but it has no ref {ref}",
                )
            else:
                self.inconclusive(pointer, answer)
            return

        if kind in {"blob", "tree", "raw"} and len(rest) >= 2:
            self.resolve_ref_and_path(pointer, owner, repo, rest, fragment)
            return

        if kind in {"issues", "pull"} and rest and rest[0].isdigit():
            number = rest[0]
            # One endpoint answers for both: a pull request is an issue here.
            answer = self.cached(f"repos/{owner}/{repo}/issues/{number}")
            if answer.status == 200:
                pointer.decide("ok", "issue-resolved", scope="issue")
            elif answer.status == 404:
                pointer.decide(
                    "broken",
                    "issue-not-found",
                    f"the repository is visible, but it has no #{number}",
                )
            else:
                self.inconclusive(pointer, answer)
            return

        if kind == "actions" and len(rest) >= 2 and rest[0] == "runs" and rest[1].isdigit():
            answer = self.cached(f"repos/{owner}/{repo}/actions/runs/{rest[1]}")
            if answer.status == 200:
                pointer.decide("ok", "run-resolved", scope="workflow run")
            elif answer.status == 404:
                pointer.decide(
                    "broken",
                    "run-not-found",
                    f"the repository is visible, but it has no workflow run {rest[1]}",
                )
            else:
                self.inconclusive(pointer, answer)
            return

        # Some other surface of a repository this credential can see. The
        # repository resolved, so say exactly that and no more.
        pointer.decide("ok", "repo-resolved", scope="repository")

    def resolve_ref_and_path(
        self, pointer: Pointer, owner: str, repo: str, rest: list[str], fragment: str
    ) -> None:
        """Split /blob/<ref>/<path> without assuming the ref holds no slash.

        A branch name containing a slash is the norm in this repository, so
        blob/fm/some-branch/docs/x.md has several readings and only the API can
        say which one is real. Every reading is offered to the contents endpoint;
        if none of them holds a file, the candidate refs themselves are looked up,
        because "this ref exists and the path is not in it" is evidence while "no
        reading of this URL names a ref I can see" is not. Guessing the split and
        reporting broken would manufacture a definitive verdict on a correct
        pointer, which costs more trust than it could ever buy.
        """
        for cut in range(1, len(rest)):
            answer = self.contents(owner, repo, "/".join(rest[cut:]), "/".join(rest[:cut]))
            if answer.status == 200:
                pointer.decide(
                    "ok",
                    "path-resolved",
                    scope="file" if not fragment else "file (fragment not checked)",
                )
                return
            if answer.status != 404:
                self.inconclusive(pointer, answer)
                return

        visible_refs: list[int] = []
        for cut in range(1, len(rest) + 1):
            answer = self.ref_exists(owner, repo, "/".join(rest[:cut]))
            if answer.status == 200:
                visible_refs.append(cut)
            elif answer.status not in {404, 422}:
                self.inconclusive(pointer, answer)
                return

        if len(rest) in visible_refs:
            # The whole tail was the ref: /tree/fm/some-branch names a branch,
            # not a path inside one.
            pointer.decide("ok", "ref-resolved", scope="ref")
            return
        if visible_refs:
            cut = visible_refs[0]
            pointer.decide(
                "broken",
                "path-not-found",
                f"the repository is visible and has ref {'/'.join(rest[:cut])}, "
                f"but {'/'.join(rest[cut:])} is not in it at that ref",
            )
            return
        pointer.decide(
            "unverified",
            "ref-not-resolved",
            f"the repository is visible, but no reading of {'/'.join(rest)} names a ref this "
            "credential can see, so which part is the ref and which the path stays undecided - "
            "that is not evidence against the pointer",
        )

    def inconclusive(self, pointer: Pointer, answer: Answer) -> None:
        if answer.status is None:
            pointer.decide("unverified", "no-answer", answer.detail or "the GitHub API did not answer")
        elif answer.status in {403, 429}:
            pointer.decide(
                "unverified",
                "rate-limited-or-forbidden",
                answer.detail or f"HTTP {answer.status} from the GitHub API",
            )
        else:
            pointer.decide(
                "unverified",
                "unexpected-status",
                answer.detail or f"HTTP {answer.status} from the GitHub API",
            )


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
        help="exit 2 when the run could not verify anything, instead of passing having verified nothing",
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
        pointers.extend(
            extract_pointers(display_path(path, root), text, path.suffix.lower() in MARKDOWN_SUFFIXES)
        )

    resolver = GitHubResolver(os.environ.get("FM_POINTER_CHECK_GH", "gh"))
    resolvable = [p for p in pointers if p.resolvable]
    # Under --require-credential the credential is probed even when there is
    # nothing to resolve, so the run can report the state of the thing the flag
    # is about rather than staying silent about it.
    if resolvable or args.require_credential:
        resolver.probe_credential()
        credential = resolver.credential
    else:
        credential = "not-probed"
    for pointer in pointers:
        if pointer.resolvable:
            resolver.resolve(pointer)

    counts = {"ok": 0, "broken": 0, "unverified": 0, "skipped": 0}
    for pointer in pointers:
        counts[pointer.verdict] += 1

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
        if credential not in {"authenticated", "not-probed"}:
            # Say the thing outright rather than leaving a reader to infer it
            # from a column of unverified pointers.
            print(
                f"fm-pointer-check: no pointer was resolved against the GitHub API "
                f"(credential={credential}: {resolver.credential_detail or 'unknown reason'}).",
            )
        if counts["unverified"]:
            print(
                "fm-pointer-check: 'unverified' is not a pass and not a failure - "
                "those pointers were not resolved either way.",
            )

    if args.require_credential:
        # A throttled probe is deliberately not in this branch: throttling is
        # never evidence and never a failure, here as everywhere else.
        refusal = ""
        if credential in {"none", "unusable"}:
            refusal = (
                "no usable GitHub credential is available "
                f"({resolver.credential_detail or 'unknown reason'})"
            )
        elif not resolvable:
            refusal = (
                "no pointer was found to resolve, so the run verified nothing - this flag is "
                "not satisfiable by absence, and a prose surface that suddenly holds no pointer "
                "is a finding rather than a pass"
            )
        if refusal:
            print(f"fm-pointer-check: --require-credential was given but {refusal}.", file=sys.stderr)
            return 2
    return 1 if counts["broken"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except UsageError as exc:
        print(f"fm-pointer-check: {exc}", file=sys.stderr)
        sys.exit(2)
PY
