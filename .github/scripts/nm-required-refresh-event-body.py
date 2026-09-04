#!/usr/bin/env python3
"""Replace github.event.pull_request.body with the live pull-request body.

The require-no-mistakes action reads GITHUB_EVENT_PATH when the caller does
not pass pr-body. A pull_request synchronize webhook carries the body as it
was at push time, which is the previous head's attestation. GitHub reruns
replay that same snapshot, so they cannot see a body the pipeline wrote
afterwards.

This helper fetches the live body (or a test fixture) and writes it into the
event payload before the pinned action runs. It does not check out the PR
and it does not change the triggering head SHA.

The fetch is a bounded wait, not a single read: it polls every --interval-sec
for up to --timeout-sec until the live attestation binds the expected head,
because the pipeline writes that body shortly after publishing the head. It
stops early on a body no pipeline owns, since no attestation is coming for
one. A body still stale when the budget is spent is written through anyway,
so the action reports the real mismatch instead of a missing signature.

Failing to read a live body is a degrade, never a verdict: the helper warns
and exits 0, leaving the webhook snapshot in the payload for the pinned
action, which owns the compliance verdict, to judge.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import sys
import time
import urllib.request

ATTESTATION_PREFIX = "<!-- no-mistakes-pipeline-attestation:v1 "
ATTESTATION_SUFFIX = " -->"
SIGNATURE_MARKER = (
    "Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)"
)


class LiveBodyUnavailable(Exception):
    """The live pull-request body could not be read on this attempt."""


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--event-path",
        default=os.environ.get("GITHUB_EVENT_PATH", ""),
        help="GITHUB_EVENT_PATH JSON to rewrite",
    )
    parser.add_argument(
        "--body-file",
        default=os.environ.get("NM_REQUIRED_BODY_FILE", ""),
        help="Fixture body; when set, skip the GitHub API",
    )
    parser.add_argument(
        "--expected-head",
        default=os.environ.get("NM_REQUIRED_EXPECTED_HEAD", ""),
        help="Triggering PR head SHA this run is judging",
    )
    parser.add_argument(
        "--timeout-sec",
        type=float,
        default=float(os.environ.get("NM_REQUIRED_BODY_TIMEOUT_SEC", "120")),
        help="Seconds to wait for the live attestation to bind the expected head",
    )
    parser.add_argument(
        "--interval-sec",
        type=float,
        default=float(os.environ.get("NM_REQUIRED_BODY_INTERVAL_SEC", "8")),
        help="Sleep between live-body fetches while waiting for a matching attestation",
    )
    return parser.parse_args(argv)


def attestation_head(body: str) -> str:
    start = body.find(ATTESTATION_PREFIX)
    if start < 0:
        return ""
    start += len(ATTESTATION_PREFIX)
    end = body.find(ATTESTATION_SUFFIX, start)
    if end < 0:
        return ""
    try:
        payload = json.loads(body[start:end])
    except json.JSONDecodeError:
        return ""
    head = payload.get("head_sha") if isinstance(payload, dict) else None
    return head if isinstance(head, str) else ""


def raised_through_no_mistakes(body: str) -> bool:
    """Whether the pipeline has ever written to this body.

    A body carrying neither marker was hand-authored, so no amount of waiting
    can produce an attestation bound to the triggering head; the pinned action
    can reject it now. A body carrying either marker is one the pipeline owns,
    and its attestation may still be a push behind, which is the wait this
    helper exists for.
    """
    return ATTESTATION_PREFIX in body or SIGNATURE_MARKER in body


def fetch_live_body(args: argparse.Namespace, number: int, owner: str, repo: str) -> str:
    if args.body_file:
        try:
            with open(args.body_file, encoding="utf-8") as handle:
                return handle.read()
        except OSError as err:
            raise LiveBodyUnavailable(str(err)) from err

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    if not token:
        raise LiveBodyUnavailable("GITHUB_TOKEN is required to fetch the live pull-request body")
    api = os.environ.get("GITHUB_GRAPHQL_URL") or "https://api.github.com/graphql"
    query = {
        "query": (
            "query($o:String!,$n:String!,$p:Int!){"
            "repository(owner:$o,name:$n){pullRequest(number:$p){body}}}"
        ),
        "variables": {"o": owner, "n": repo, "p": number},
    }
    request = urllib.request.Request(
        api,
        data=json.dumps(query).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "firstmate-nm-required-refresh",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, http.client.HTTPException, json.JSONDecodeError) as err:
        raise LiveBodyUnavailable(str(err)) from err
    if not isinstance(payload, dict):
        raise LiveBodyUnavailable(f"unexpected response shape: {payload!r}")
    errors = payload.get("errors")
    if errors:
        raise LiveBodyUnavailable(f"GraphQL errors: {errors}")
    try:
        body = payload["data"]["repository"]["pullRequest"]["body"]
    except (KeyError, TypeError) as err:
        raise LiveBodyUnavailable(f"no body in response: {payload}") from err
    return body if isinstance(body, str) else ""


def load_event(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            event = json.load(handle)
    except (OSError, json.JSONDecodeError) as err:
        raise SystemExit(f"could not read event payload {path}: {err}") from err
    if not isinstance(event, dict):
        raise SystemExit(f"event payload {path} is not a JSON object")
    return event


def pull_request_from_event(event: dict) -> dict:
    pr = event.get("pull_request")
    if not isinstance(pr, dict):
        raise SystemExit("event payload has no pull_request object")
    return pr


def expected_head_from(args: argparse.Namespace, pr: dict) -> str:
    if args.expected_head.strip():
        return args.expected_head.strip()
    head = pr.get("head") if isinstance(pr.get("head"), dict) else {}
    sha = head.get("sha")
    return sha.strip() if isinstance(sha, str) else ""


def repository_parts() -> tuple[str, str]:
    slug = os.environ.get("GITHUB_REPOSITORY") or ""
    if "/" not in slug:
        raise LiveBodyUnavailable("GITHUB_REPOSITORY is required to fetch the live pull-request body")
    owner, repo = slug.split("/", 1)
    return owner, repo


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.event_path:
        raise SystemExit("GITHUB_EVENT_PATH or --event-path is required")
    event = load_event(args.event_path)
    pr = pull_request_from_event(event)
    number = pr.get("number")
    if not isinstance(number, int):
        raise SystemExit("event pull_request.number is missing")
    expected = expected_head_from(args, pr)
    owner = repo = ""
    try:
        if not args.body_file:
            owner, repo = repository_parts()
    except LiveBodyUnavailable as err:
        print(f"::warning::live pull-request body unavailable ({err}); "
              "leaving the webhook snapshot in the event payload")
        return 0

    deadline = time.monotonic() + max(args.timeout_sec, 0)
    interval = args.interval_sec if args.interval_sec > 0 else 0
    body: str | None = None
    last_error = ""
    warned = False
    while True:
        try:
            body = fetch_live_body(args, number, owner, repo)
        except LiveBodyUnavailable as err:
            # The budget decides when to give up, not the first blip: an
            # attempt that fails leaves the previous body in place and the wait
            # runs on, so one transient cannot strand a push the pipeline is
            # still writing the attestation for.
            last_error = str(err)
            if body is not None and not warned:
                warned = True
                print(f"::warning::live pull-request body fetch failed ({last_error}); "
                      "retrying on the last body read until the wait budget is spent")
        else:
            if attestation_head(body) == expected:
                break
            if not raised_through_no_mistakes(body):
                break
        if time.monotonic() >= deadline:
            break
        if interval > 0:
            time.sleep(interval)

    if body is None:
        # The pinned action, not this helper, owns the compliance verdict: an
        # unreachable API leaves the webhook snapshot for it to judge instead
        # of reddening the required check with no verdict at all.
        print(f"::warning::live pull-request body unavailable ({last_error}); "
              "leaving the webhook snapshot in the event payload")
        return 0

    pr["body"] = body
    bound = attestation_head(body) or "(missing)"
    triggering = expected or "(missing)"
    print(
        f"Refreshed pull_request.body from the live pull request "
        f"(attestation.head_sha={bound}; triggering head={triggering})."
    )
    with open(args.event_path, "w", encoding="utf-8") as handle:
        json.dump(event, handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
