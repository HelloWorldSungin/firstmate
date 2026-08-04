# Projects

Cross-forge registry fixture for tests/fm-issue-linkage.test.sh. One project per
case the tracker contract has to get right: a GitHub project, a Gitea project on
a self-hosted host, a project whose clone directory disagrees with its declared
tracker, a project that declares no tracker at all, a project that declares it
has none, and a project whose declaration is malformed - empty, unparseable, or
ambiguously doubled.

- gh-project [no-mistakes +yolo tracker=github:github.com/HelloWorldSungin/gh-project] - ordinary GitHub tracker (added 2026-08-04)
- gitea-project [direct-PR tracker=gitea:gitea.example.com/DuckKingOri/gitea-project] - self-hosted Gitea tracker (added 2026-08-04)
- renamed-clone [no-mistakes +yolo tracker=github:github.com/HelloWorldSungin/renamed-upstream] - the clone directory keeps the old spelling while the tracker names the renamed repository (added 2026-08-04)
- mirrored-project [no-mistakes tracker=gitea:gitea.example.com/DuckKingOri/mirrored-project] - code is mirrored on GitHub while issues are tracked on Gitea, so the git remote must never decide the tracker (added 2026-08-04)
- untracked-project [no-mistakes +yolo] - declares no tracker at all (added 2026-08-04)
- trackerless-project [direct-PR tracker=none] - explicitly declares it has no tracker (added 2026-08-04)
- malformed-project [no-mistakes tracker=bogus:not-a-host] - a typo'd declaration that must be reported, never read as undeclared (added 2026-08-04)
- empty-tracker-project [no-mistakes tracker=] - an empty declaration that must be reported, never read as undeclared (added 2026-08-04)
- double-tracker-project [no-mistakes tracker=github:github.com/HelloWorldSungin/first-tracker tracker=gitea:gitea.example.com/DuckKingOri/second-tracker] - two declarations in one entry, which names no authoritative tracker and must be refused rather than resolved by position (added 2026-08-04)
- gitlab-project [no-mistakes tracker=gitlab:gitlab.example.com/group/subgroup/proj] - nested GitLab namespace (added 2026-08-04)
