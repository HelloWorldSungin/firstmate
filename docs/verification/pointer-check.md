# Cross-system pointer resolution verification

Repeatable evidence that [`bin/fm-pointer-check.sh`](../../bin/fm-pointer-check.sh) separates a broken pointer from one it could not verify.
The convention it serves is owned by [`../one-owner.md`](../one-owner.md) and the flags by the script's own header and `--help`; this page records evidence only.

Date: 2026-08-11.
Shell: GNU bash 5.2.21 (Linux).
Client: `gh version 2.93.0`, authenticated as a token that can read `HelloWorldSungin/*`.

## The trap, before the check

A private repository and a repository whose owner never existed answer an unauthenticated request identically.
Both of the following name a real, deliberate case: the first is a correct pointer into a private repository, the second names an owner account that does not exist.

```console
$ curl -s -o /dev/null -w "%{http_code}\n" https://api.github.com/repos/HelloWorldSungin/ArkNode-AI
404
$ curl -s -o /dev/null -w "%{http_code}\n" https://api.github.com/repos/HelloWorldSungin-nope-9f3a/ArkNode-AI
404
```

A two-verdict checker reading those responses must call one of the two wrong.
That is the case this check is built around, not a hypothetical.

## The constructed cases

Seven pointers, covering every outcome the resolver can reach.
The last two are the ref/path split: `fm/`-prefixed branch names are the norm in this repository, so a blob URL does not divide into ref and path at the first slash, and a checker that assumes it does reports a correct pointer as definitively broken.

```markdown
[private repo, correct path](https://github.com/HelloWorldSungin/ArkNode-AI/blob/master/docs/design/2026-08-10-ct110-sealed-corpus.md)
[owner that does not exist](https://github.com/HelloWorldSungin-nope-9f3a/ArkNode-AI/blob/master/docs/design/2026-08-10-ct110-sealed-corpus.md)
[owner exists, repo not visible](https://github.com/torvalds/definitely-not-a-real-repo-x9q7/blob/master/README.md)
[visible repo, absent path](https://github.com/HelloWorldSungin/firstmate/blob/main/docs/this-file-does-not-exist.md)
[visible repo, absent issue](https://github.com/HelloWorldSungin/firstmate/issues/999999)
[slash in the branch name](https://github.com/HelloWorldSungin/firstmate/blob/fm/fm-design-profile/README.md)
[no reading names a ref](https://github.com/HelloWorldSungin/firstmate/blob/fm/fm-no-such-branch/README.md)
```

### Authenticated

```console
$ bin/fm-pointer-check.sh --verbose /tmp/pointer-cases.md
ok         /tmp/pointer-cases.md:1  https://github.com/HelloWorldSungin/ArkNode-AI/blob/master/docs/design/2026-08-10-ct110-sealed-corpus.md  path-resolved [scope=file]
broken     /tmp/pointer-cases.md:2  https://github.com/HelloWorldSungin-nope-9f3a/ArkNode-AI/blob/master/docs/design/2026-08-10-ct110-sealed-corpus.md  owner-not-found
           github.com/HelloWorldSungin-nope-9f3a does not exist
unverified /tmp/pointer-cases.md:3  https://github.com/torvalds/definitely-not-a-real-repo-x9q7/blob/master/README.md  repo-not-visible
           github.com/torvalds exists but this credential cannot see torvalds/definitely-not-a-real-repo-x9q7: private and inaccessible is indistinguishable from absent, so this is not evidence either way
broken     /tmp/pointer-cases.md:4  https://github.com/HelloWorldSungin/firstmate/blob/main/docs/this-file-does-not-exist.md  path-not-found
           the repository is visible and has ref main, but docs/this-file-does-not-exist.md is not in it at that ref
broken     /tmp/pointer-cases.md:5  https://github.com/HelloWorldSungin/firstmate/issues/999999  issue-not-found
           the repository is visible, but it has no #999999
ok         /tmp/pointer-cases.md:6  https://github.com/HelloWorldSungin/firstmate/blob/fm/fm-design-profile/README.md  path-resolved [scope=file]
unverified /tmp/pointer-cases.md:7  https://github.com/HelloWorldSungin/firstmate/blob/fm/fm-no-such-branch/README.md  ref-not-resolved
           the repository is visible, but no reading of fm/fm-no-such-branch/README.md names a ref this credential can see, so which part is the ref and which the path stays undecided - that is not evidence against the pointer
fm-pointer-check: checked=7 ok=2 broken=3 unverified=2 skipped=0 files=1 credential=authenticated
fm-pointer-check: 'unverified' is not a pass and not a failure - those pointers were not resolved either way.
$ echo $?
1
```

The pointer whose repository is private resolves; the pointer whose owner does not exist is broken.
With a credential those two are distinguishable, and the distinction is what the check exists to make.

Lines 4 and 6 are the pair that keeps `broken` honest.
Line 6 is a correct pointer whose branch name contains a slash, and it resolves; line 4 is only called broken after the API confirms the ref itself exists, which is what the detail line states.
Line 7 is the case where neither is establishable: no reading of the URL names a ref this credential can see, so the split is undecided and the answer is could-not-verify rather than a fabricated broken.

### The same file with no credential

```console
$ GH_CONFIG_DIR=$(mktemp -d) GH_TOKEN= GITHUB_TOKEN= bin/fm-pointer-check.sh --verbose /tmp/pointer-cases.md
unverified /tmp/pointer-cases.md:1  ...  no-credential
           To get started with GitHub CLI, please run:  gh auth login
unverified /tmp/pointer-cases.md:2  ...  no-credential
           To get started with GitHub CLI, please run:  gh auth login
unverified /tmp/pointer-cases.md:3  ...  no-credential
unverified /tmp/pointer-cases.md:4  ...  no-credential
unverified /tmp/pointer-cases.md:5  ...  no-credential
unverified /tmp/pointer-cases.md:6  ...  no-credential
unverified /tmp/pointer-cases.md:7  ...  no-credential
fm-pointer-check: checked=7 ok=0 broken=0 unverified=7 skipped=0 files=1 credential=none
fm-pointer-check: no pointer was resolved against the GitHub API (credential=none: To get started with GitHub CLI, please run:  gh auth login).
fm-pointer-check: 'unverified' is not a pass and not a failure - those pointers were not resolved either way.
$ echo $?
0
```

`ok=0 broken=0` is the whole point.
Unauthenticated, the correct pointer at line 1 and the broken one at line 2 are the same 404, so the check claims neither.
It exits 0, because failing to reach a target is not evidence against the target, and it says outright that it resolved nothing rather than leaving that to be inferred from a column of verdicts.

### Refusing a run that verified nothing

Two ways to verify nothing, both refused under the flag: no usable credential, and no pointer to resolve.
The second matters because a regression in the extraction would otherwise turn a silent pointer surface into a green run.

```console
$ GH_CONFIG_DIR=$(mktemp -d) GH_TOKEN= GITHUB_TOKEN= bin/fm-pointer-check.sh --require-credential /tmp/pointer-cases.md
fm-pointer-check: --require-credential was given but no usable GitHub credential is available (To get started with GitHub CLI, please run:  gh auth login).
$ echo $?
2
$ bin/fm-pointer-check.sh --require-credential /tmp/no-pointers.md
fm-pointer-check: --require-credential was given but no pointer was found to resolve, so the run verified nothing - this flag is not satisfiable by absence, and a prose surface that suddenly holds no pointer is a finding rather than a pass.
fm-pointer-check: checked=0 ok=0 broken=0 unverified=0 skipped=0 files=1 credential=authenticated
$ echo $?
2
```

CI runs the check with this flag, so a lost credential surfaces as its own failure rather than as a green run over unresolved pointers.

### The credential the probe has to answer for

CI passes `GH_TOKEN: ${{ github.token }}`, a GitHub App installation token, which is refused at every user-context endpoint.
The probe therefore asks `rate_limit`, which answers for any credential and discloses the core ceiling; the unauthenticated one is 60 requests an hour and no real credential is that low.

```console
$ curl -s https://api.github.com/rate_limit -D - -o /dev/null | grep -i '^x-ratelimit-limit'
x-ratelimit-limit: 60
$ gh api -i rate_limit | grep -i '^x-ratelimit-limit'
X-Ratelimit-Limit: 5000
```

The installation-token shape itself cannot be exercised from a workstation, so it is pinned offline instead: the stub in `tests/fm-pointer-check.test.sh` answers `user` with 403 exactly as GitHub does for that token, and the test asserts the run still reports `credential=authenticated` and resolves its pointer.

### A transport failure lands in the same safe place

One authenticated run of case 3 was intercepted by this host's egress TLS, mid-suite and unplanned:

```console
unverified /tmp/pointer-cases.md:3  ...  no-answer
           Get "https://api.github.com/users/torvalds": tls: failed to verify certificate: x509: certificate is not valid for any names, but wanted to match api.github.com
```

Three immediately repeated runs of the same case returned the stable `repo-not-visible` verdict shown above.
Both forms are `unverified` and neither is `broken`, which is the behaviour a flaky network must produce.

## The cross-repository case, on the real page

A vault operations page in a separate repository points at the design record that owns the CT110 seal, in a private repository.
The check resolves it from outside this repository, against a path given on the command line (home directory elided below; the run prints it in full):

```console
$ bin/fm-pointer-check.sh --verbose ~/firstmate/projects/arknode-vault/Trading-Signal-AI/Operations/Deployment-Guide.md
ok         ~/firstmate/projects/arknode-vault/Trading-Signal-AI/Operations/Deployment-Guide.md:189  https://github.com/HelloWorldSungin/ArkNode-AI/blob/master/docs/design/2026-08-10-ct110-sealed-corpus.md  path-resolved [scope=file]
fm-pointer-check: checked=1 ok=1 broken=0 unverified=0 skipped=0 files=1 credential=authenticated
```

That path is captain-private, so the run is reproducible only on a host holding that clone; the constructed cases above cover the same resolution shape without it.

## This repository's own tracked prose

```console
$ bin/fm-pointer-check.sh
fm-pointer-check: checked=23 ok=9 broken=0 unverified=0 skipped=14 files=88 credential=authenticated
$ echo $?
0
```

The 14 skipped pointers are hosts with no resolver in this check (`img.shields.io`, `discord.gg`, `x.com`, `skills.sh`, `herdr.dev`, `cmux.com`, `gitlab.com`, `huggingface.co`, `w3.org`, `kunchenguid.github.io`) and are reported as skipped rather than counted as verified.
No tracked page carries a placeholder URL outside a fence, so the skipped column here is all `no-adapter`; a placeholder would appear in it as `template` rather than vanish from the count.

## Offline regression

`tests/fm-pointer-check.test.sh` drives every verdict through a stub GitHub client, so the portable suite is offline and deterministic.
It asserts the verdict split rather than the presence of output: that an authenticated run separates the outcomes, that a credential-less run produces neither an `ok` nor a `broken` column, that an installation token is not mistaken for an unusable one, that `--require-credential` exits 2 for a missing credential and for an empty pointer surface but not for a throttled one, that a slashed branch name resolves while an undecidable split is could-not-verify, and that fenced and inline URLs stay out of the pointer surface while a template is refused by name.

```console
$ bin/fm-test-run.sh tests/fm-pointer-check.test.sh
ok - authenticated resolution separates ok, broken, and could-not-verify
ok - no credential yields could-not-verify, never a broken or working verdict
ok - a GitHub App installation token is probed as usable, not as unusable
ok - --require-credential turns a credential-less run into an explicit refusal
ok - a throttled or forbidden lookup is could-not-verify, never broken
ok - a branch name containing a slash resolves, and an undecidable split is not broken
ok - fenced and inline URLs stay out of the pointer surface, and a template is refused by name
ok - pointers in code comments are resolved, not only Markdown links
ok - JSON output reports every pointer, verdict, and reason
ok - the default scan selects tracked Markdown and reports repo-relative sources
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=495
```

The live half of this page - real credential, real private repository, real nonexistent owner, real slashed branch name - is what the stub cannot prove, and is the reason these commands are recorded rather than assumed.
Re-run them after a change to the resolution ladder or to the `gh` major version.
