# Documentation audience cleanup verification

Audience: maintainer verification.

This record verifies the current audience split against base commit `d89a1b69115525f9c3b1cef03615afabee186ff7` and cleanup target `316aa78c8538bbc1c468fa66610cfb69f01f4ef0` on 2026-07-23.
The target includes the repaired cmux safety pointer, and the later addition of this evidence record does not change any measured prompt surface.

## Prompt-bearing reductions

The prompt measurement covers the always-loaded `AGENTS.md` contract and the harness-specific operating block rendered by `bin/fm-supervision-instructions.sh`.
Whitespace-delimited words and UTF-8 bytes are reported with lines so the result is reproducible without a model-specific tokenizer.
The renderer was byte-identical between the two commits.
Stable render inputs used `FM_ROOT_OVERRIDE=/firstmate`, `FM_HOME=/firstmate`, `--read-only 0`, `--afk 0`, and `--x-mode 0`.

| Prompt surface | Before | After | Reduction |
| --- | --- | --- | --- |
| Always-loaded `AGENTS.md` | 485 lines, 6,856 words, 50,500 bytes. | 485 lines, 6,851 words, 50,441 bytes. | 0 lines, 5 words, and 59 bytes, so the file remained line-growth-neutral. |
| OpenCode rendered supervision block | 31 lines, 371 words, 2,818 bytes. | 26 lines, 300 words, 2,266 bytes. | 5 lines (16.1%), 71 words (19.1%), and 552 bytes (19.6%). |
| Pi rendered supervision block | 58 lines, 840 words, 6,560 bytes. | 31 lines, 413 words, 3,259 bytes. | 27 lines (46.6%), 427 words (50.8%), and 3,301 bytes (50.3%). |
| Both changed rendered blocks | 89 lines, 1,211 words, 9,378 bytes. | 57 lines, 713 words, 5,525 bytes. | 32 lines (36.0%), 498 words (41.1%), and 3,853 bytes (41.1%). |

Claude, Codex, Grok, and unknown-harness protocol payloads were byte-identical.
Conditional skills are excluded because they are loaded only for their named situations rather than rendered into every supervision prompt.

Exact source counts:

```sh
for file in \
  AGENTS.md \
  docs/supervision-protocols/opencode.md \
  docs/supervision-protocols/pi.md
do
  git show d89a1b69115525f9c3b1cef03615afabee186ff7:"$file" | wc -l -w -c
  git show 316aa78c8538bbc1c468fa66610cfb69f01f4ef0:"$file" | wc -l -w -c
done
git diff --quiet \
  d89a1b69115525f9c3b1cef03615afabee186ff7 \
  316aa78c8538bbc1c468fa66610cfb69f01f4ef0 \
  -- bin/fm-supervision-instructions.sh
```

Observed output:

```text
485 6856 50500
485 6851 50441
21 316 2305
16 245 1753
48 785 5889
21 358 2588
renderer diff exit 0
```

Exact after-render commands:

```sh
FM_ROOT_OVERRIDE=/firstmate FM_HOME=/firstmate \
  bin/fm-supervision-instructions.sh \
  --harness opencode --read-only 0 --afk 0 --x-mode 0 | wc -l -w -c
FM_ROOT_OVERRIDE=/firstmate FM_HOME=/firstmate \
  bin/fm-supervision-instructions.sh \
  --harness pi --read-only 0 --afk 0 --x-mode 0 | wc -l -w -c
```

Observed output:

```text
26 300 2266
31 413 3259
```

The before-render counts add the exact removed protocol payload to those unchanged renderer frames.
The removed OpenCode and Pi evidence blocks contained no render placeholders, so their source line, word, and byte deltas are also their rendered deltas.

## Setup-facing reductions

The six runtime backend guides fell from 2,109 to 718 lines and from 35,525 to 5,987 words, reductions of 66.0% and 83.1%.
The four current supervision guides fell from 476 to 217 lines and from 5,992 to 2,528 words, reductions of 54.4% and 57.8%.
The README remained a concise router while falling from 2,074 to 1,938 words, a 6.6% reduction.
The evidence removed from those current guides was consolidated rather than counted as deleted durable knowledge.

The backend-guide group is `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, `docs/cmux-backend.md`, and `docs/codex-app-backend.md`.
The supervision-guide group is `docs/sessionstart-nudge.md`, `docs/turnend-guard.md`, `docs/watcher-continuity.md`, and `docs/wedge-alarm.md`.

## Preservation map

| Changed source or boundary | Durable material preserved | Canonical current owner | Evidence or regression owner |
| --- | --- | --- | --- |
| `README.md` Pi Calm detail | Current visibility, persistence, semantic-input, restore, and supported-limit behavior remains documented. | [`docs/calm.md`](../calm.md) owns current operator behavior. | [`docs/calm-mode-feasibility.md`](../calm-mode-feasibility.md) owns version-scoped render evidence and regressions. |
| Runtime backend guides | Setup, selection, topology, metadata, recovery, lifecycle, security, destructive-test safety, composer safety, and active limits remain in the individual guide. | The corresponding operator guide under `docs/*-backend.md` owns each current contract. | [`runtime-backends.md`](runtime-backends.md) owns source and live proof, with focused backend tests named by each guide. |
| `docs/architecture.md` backend summaries | Stable provider boundaries and current safety rationale remain concise architecture pointers. | [`docs/architecture.md`](../architecture.md) owns the cross-backend architecture summary. | [`runtime-backends.md`](runtime-backends.md) owns empirical backend proof. |
| Session-start guide and OpenCode and Pi rendered protocols | Current transport, scope, compatibility, lock, continuation, and extension-loading instructions remain on prompt-bearing paths. | [`docs/sessionstart-nudge.md`](../sessionstart-nudge.md) and `docs/supervision-protocols/` own current behavior and rendered instructions. | [`supervision.md`](supervision.md#native-session-start-delivery) owns dated cross-harness evidence and exact live entry points. |
| Turn-end guard guide | Predicate, scope, recursion safety, fail-open behavior, and harness compatibility remain current. | [`docs/turnend-guard.md`](../turnend-guard.md) owns the active guard contract. | [`supervision.md`](supervision.md#turn-end-guard) and `tests/fm-turnend-guard.test.sh` own empirical and deterministic proof. |
| Watcher continuity guide | Ownership, successor ordering, cycle ledger, bounded delay, and active limits remain current. | [`docs/watcher-continuity.md`](../watcher-continuity.md) owns the active continuity contract. | [`supervision.md`](supervision.md#watcher-continuity) owns the five-harness live matrix and exact commands. |
| Wedge-alarm guide | Channel behavior, consent boundary, command safety, timeout, and no-real-notification test boundary remain current. | [`docs/wedge-alarm.md`](../wedge-alarm.md) owns current operator behavior and test safety. | [`supervision.md`](supervision.md#wedge-alarm-channels) owns bounded macOS and Herdr proof. |
| `AGENTS.md` and conditional agent skills | Always-needed triggers and safety boundaries remain inline, while named procedures stay conditional. | `AGENTS.md` owns the always-loaded routing index, and each `.agents/skills/*/SKILL.md` owns its named procedure. | The 485-line before-and-after count above proves line-growth neutrality. |
| Documentation placement and review rules | Audience classes, one-owner placement, complete-diff review, and non-keyword structural validation are explicit. | [`docs/documentation-audiences.json`](../documentation-audiences.json) owns classification, while [`firstmate-coding-guidelines`](../../.agents/skills/firstmate-coding-guidelines/SKILL.md) owns placement policy. | `bin/fm-doc-audience-check.sh` and `tests/fm-documentation-audiences.test.sh` own enforcement. |
| Public versus internal Stow boundary | The standalone public skill and Firstmate-internal skill remain separate, independently evolving files with distinct routing behavior. | `skills/stow/SKILL.md` owns the public contract, and `.agents/skills/stow/SKILL.md` owns the internal contract. | Both files are byte-identical between the measured commits and remain separately classified in the audience inventory. |
| Removed chronology, local paths, run identifiers, and failed hypotheses | No current guarantee depends on retaining these task-specific details in operator pages. | Current facts were distilled into the owners above. | Private task reports or PR evidence retain delivery history when needed. |

## Structural verification

The complete classification and link check is:

```sh
bin/fm-doc-audience-check.sh
```

Expected output after this record is classified:

```text
fm-doc-audience-check: ok surfaces=55 local_links=159
```
