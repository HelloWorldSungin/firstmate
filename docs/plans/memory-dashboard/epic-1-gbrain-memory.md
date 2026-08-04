# Epic 1: gbrain memory integration with fully-local GPU embeddings

## Epic

**Title:** Epic: gbrain memory integration with fully-local GPU embeddings

**Body:**

### Problem

Firstmate's memory is a set of curated markdown files (`data/captain.md`, `data/learnings.md`, `data/projects.md`, `data/backlog.md`, per-task briefs/reports) read wholesale into context at session start. At 5+ managed projects this saturates: the digest grows, `learnings.md`'s prune-don't-append contract forces knowledge to be discarded, and completed scout reports / task outcomes become unfindable.

### Goal

Integrate [gbrain](https://github.com/garrytan/gbrain) as a **searchable archive tier behind** the canonical memory files - not a replacement for them. All embedding and reranking runs locally on the homelab's 4x RTX 5060 Ti 16GB GPUs: no per-token cloud cost, no memory content leaves the box.

### Architecture decisions (from research)

- **Canonical files stay canonical.** `captain.md`, `learnings.md`, `projects.md`, `backlog.md` remain the always-loaded contract per `AGENTS.md` §2/§6. gbrain absorbs overflow: completed scout reports, done-task briefs and outcomes, pruned `learnings.md` prose, per-project gotchas.
- **gbrain in PGLite mode** (embedded Postgres via WASM) - zero extra infrastructure; the markdown brain repo in git remains the system of record.
- **Local embeddings via gbrain's `ollama:` or `llama-server:` recipe** (`gbrain init --embedding-model ollama:<model> --embedding-dimensions <N>`; `OLLAMA_BASE_URL` / `LLAMA_SERVER_BASE_URL`). Local cross-encoder rerank via the `llama-server-reranker` recipe (Qwen3-Reranker). Confirmed upstream in `docs/integrations/embedding-providers.md`.
- **Retrieval on demand, not at session start.** Crewmates query via CLI (`gbrain search` / `gbrain think`) to avoid loading 30+ MCP tool schemas into every worker context. The primary may optionally attach a trimmed MCP toolset.
- **Ingestion at natural lifecycle points:** task teardown and the `/stow` knowledge-routing sweep.
- **Scoping:** one brain per `FM_HOME`; the main home's brain shared read-only to secondmate homes (mirrors the existing `captain-shared.md` inheritance pattern).

### Stories and dispatch plan

| # | Story | Harness / model | Effort | Why |
|---|---|---|---|---|
| 1 | Local embedding + reranker serving on the GPU rig | codex | medium | Documented ops work; bump to high only if source-building llama.cpp for Blackwell gets fiddly |
| 2 | gbrain install, init, and smoke test | codex | medium | Explicit, well-documented steps against a new tool |
| 3 | Archive-tier ingestion: teardown and /stow hooks + backfill | claude / Opus | high | Touches firstmate shared tracked material and teardown safety contracts |
| 4 | Retrieval integration for firstmate and crewmates | claude / Opus | high | Edits brief scaffolds and AGENTS.md contract wording |
| 5 | Brain scoping and secondmate inheritance policy | claude / Opus | xhigh | Ambiguous design across FM_HOME isolation and secondmate-provisioning machinery |
| 6 | Evaluation, migration playbook, and dream-cycle decision | claude / Opus | xhigh | Scout-type investigation and judgment-heavy go/no-go |

Rationale: the $200 Claude subscription carries the contract-sensitive firstmate-internals stories (plus primary supervision itself); the $100 Codex subscription carries the bounded, spec-driven infra stories. Per-task overrides remain the captain's call at dispatch time.

### Epic acceptance criteria

- [ ] Embedding + rerank endpoints served locally on the GPU rig, surviving reboot
- [ ] gbrain initialized (PGLite, pinned version) against the local endpoints; smoke-tested end to end
- [ ] Completed scout reports and done-task outcomes are ingested automatically and retrievable by semantic search
- [ ] Crewmates can query the brain from a ship/scout brief with a one-line instruction
- [ ] Session-start digest size and behavior unchanged (no regression to the read-once contract)
- [ ] Zero cloud API calls in the embedding/rerank path

### Non-goals

- Replacing or migrating the canonical markdown memory files
- Cloud embedding providers (OpenAI/Voyage/ZeroEntropy)
- The 24/7 "dream cycle" enrichment as part of this epic (requires an LLM; evaluated in story 6)

### References

- gbrain: https://github.com/garrytan/gbrain (MIT, TypeScript/Bun, PGLite/Postgres+pgvector, hybrid vector+BM25+graph retrieval, MCP + CLI + thin-client)
- Embedding provider recipes: https://github.com/garrytan/gbrain/blob/master/docs/integrations/embedding-providers.md
- Firstmate hook points: `bin/fm-teardown.sh`, `.agents/skills/stow`, `bin/fm-brief.sh`

---

### Story 1: Local embedding + reranker serving on the GPU rig

**Title:** gbrain 1/6: Serve local embedding + reranker endpoints on the 4x RTX 5060 Ti rig

**Body:**

Part of the gbrain memory epic. Stand up OpenAI-compatible embedding and rerank endpoints on the homelab GPUs so gbrain (and anything else) can use them with zero cloud calls.

**Suggested dispatch:** codex, medium effort (bump to high only if a source build of llama.cpp for Blackwell is needed).

#### Hardware and compatibility notes

- 4x RTX 5060 Ti 16GB = Blackwell GB206, compute capability `sm_120`. Requires CUDA 12.8+.
- Ollama prebuilt binaries support RTX 50-series out of the box - preferred first path.
- llama.cpp built from source needs `CMAKE_CUDA_ARCHITECTURES="120"` (older toolchains error with "Unsupported gpu architecture 'compute_120'").
- Benchmarks on a single 5060 Ti 16GB show ~90-100 tok/s on 7B-class models, so embedding throughput for a personal corpus is far beyond what firstmate needs.

#### GPU allocation plan

| GPU | Role | Serving |
|---|---|---|
| 0 | Embeddings | Ollama (or llama-server `--embeddings`) |
| 1 | Reranker | llama-server `--reranking` with Qwen3-Reranker (0.6B or 4B, Q8) |
| 2-3 | Reserve | Free for a future local LLM (dream cycle experiments, story 6) or other homelab inference |

Pin devices with `CUDA_VISIBLE_DEVICES` per service unit.

#### Model choice

Start with **`snowflake-arctic-embed-l-v2` (1024d)** - upstream gbrain guidance is "stay at 1024 or 1536" dimensions; it is fast, light (<2GB), and strong. If retrieval quality in story 6 disappoints, step up to **`qwen3-embed-8b` (4096d)**, which fits a 16GB card at Q8 (~8.5GB) but costs 4x the vector storage. Switching later is supported via `gbrain reinit-pglite --embedding-model ... --embedding-dimensions ...` (full re-embed, cheap at local speeds).

#### Scope

- [ ] Install Ollama (or build llama-server) on the homelab server; verify GPU inference on a 5060 Ti (`nvidia-smi` shows the model loaded on the intended GPU)
- [ ] Pull/serve the chosen embedding model; verify `POST /v1/embeddings` (OpenAI-compatible, default `http://localhost:11434/v1` for Ollama)
- [ ] Serve Qwen3-Reranker via `llama-server --reranking` on GPU 1; verify the rerank endpoint
- [ ] systemd units (or equivalent) with restart-on-failure and boot persistence, `CUDA_VISIBLE_DEVICES` pinned per unit
- [ ] Endpoints bound to localhost (gbrain runs on the same box); document ports
- [ ] Record chosen model, dimensions, and endpoints in this home's local config notes for story 2

#### Acceptance criteria

- Embedding endpoint returns correct-dimensionality vectors after a server reboot with no manual step
- Reranker endpoint reorders a test query/passage set sensibly
- Both services visible on their pinned GPUs in `nvidia-smi`
- No external network calls during embed/rerank (spot-check)

---

### Story 2: gbrain install, init, and smoke test

**Title:** gbrain 2/6: Install and initialize gbrain (PGLite + local embedding recipe), end-to-end smoke test

**Body:**

Part of the gbrain memory epic. Depends on story 1 (local endpoints).

**Suggested dispatch:** codex, medium effort.

#### Scope

- [ ] Install gbrain at a **pinned version/tag** (`bun install -g github:garrytan/gbrain#<tag>`) - the project is young and fast-moving; upgrades should be deliberate
- [ ] `gbrain init --pglite --embedding-model ollama:<model> --embedding-dimensions <N>` pointing at story 1's endpoint (`OLLAMA_BASE_URL`). Note: local recipes are never auto-detected (no API key), so the explicit flag is required; gbrain trusts the declared dimension for local recipes, so it must match the model exactly
- [ ] Configure the `llama-server-reranker` recipe against story 1's rerank endpoint (upstream walkthrough: `docs/ai-providers/llama-server-reranker.md`)
- [ ] Decide and document the brain repo location (markdown system of record, its own git repo, NOT under `projects/` and NOT inside the firstmate repo; suggested: a sibling private repo or bare clone on the homelab)
- [ ] Smoke test: `gbrain capture` 20-30 real documents (a few existing scout reports, some learnings prose), then verify `gbrain search` returns relevant hits and `gbrain think` produces a cited synthesis
- [ ] Confirm PGLite footprint and location; note backup story (the markdown repo is the recovery source - the index is rebuildable)

#### Acceptance criteria

- `gbrain search "<known topic from an ingested report>"` returns the right page in top 5
- `gbrain think` answers a question spanning 2+ ingested documents with citations
- No cloud embedding calls (verify endpoint logs / network)
- Version pin and exact init command recorded in `docs/` or the home's local notes so the setup is reproducible

---

### Story 3: Archive-tier ingestion - teardown and /stow hooks + backfill

**Title:** gbrain 3/6: Ingest task knowledge into the brain at teardown and /stow; backfill existing reports

**Body:**

Part of the gbrain memory epic. Depends on story 2. This is the story that actually relieves memory pressure: knowledge that today gets pruned or buried becomes searchable instead.

**Suggested dispatch:** claude (Opus), high effort - touches firstmate shared tracked material and teardown safety contracts.

#### Ingestion sources

| Source | When | Content |
|---|---|---|
| `data/<id>/report.md` | Scout task completion/teardown | Full report, tagged with project + task id |
| `data/<id>/brief.md` + outcome | Ship task teardown | Brief summary, PR URL, outcome one-liner |
| Pruned `learnings.md` prose | `/stow` sweep and inspect-then-update rewrites | Superseded-but-true knowledge routed to the brain instead of deleted |
| Per-project gotchas below `AGENTS.md` threshold | `/stow` | Project-tagged notes |

#### Design constraints

- Ingestion is **additive and out-of-band**: a capture failure must never block or fail teardown itself (log a warning, continue - teardown's landed-work safety contract stays untouched)
- Firstmate's project-write boundary is unaffected: the brain repo is not under `projects/`
- Captures carry structured front-matter/tags: `project`, `task_id`, `kind` (scout-report | ship-outcome | learning | gotcha), `date`
- The `/stow` skill's knowledge-routing decision tree (`.agents/skills/stow`) gains one new route: "archive to brain" alongside existing destinations; captain-private strategy still never leaves `data/`

#### Scope

- [ ] `bin/fm-brain-capture.sh` helper: wraps `gbrain capture` with tags, fails soft, no-ops cleanly when gbrain is absent/unconfigured (presence-gated like other optional integrations)
- [ ] Teardown integration: on successful ship/scout teardown, capture the report/brief+outcome
- [ ] `/stow` skill update: route pruned learnings and sub-threshold gotchas to the brain
- [ ] Backfill script or one-shot task: ingest all existing `data/*/report.md` and Done-task briefs
- [ ] Ship through the normal firstmate PR path (`firstmate-coding-guidelines` applies - shared tracked material)

#### Acceptance criteria

- Completing a scout task results in its report being findable via `gbrain search` without manual steps
- A teardown with the brain unavailable still completes normally and logs the skipped capture
- Backfilled historical reports retrievable by project tag

---

### Story 4: Retrieval integration for firstmate and crewmates

**Title:** gbrain 4/6: CLI-first brain retrieval for firstmate and crewmates; brief scaffold hook

**Body:**

Part of the gbrain memory epic. Depends on story 2 (works best after story 3 has populated the brain).

**Suggested dispatch:** claude (Opus), high effort - edits brief scaffolds and AGENTS.md contract wording.

#### Design

- **CLI-first for workers.** Crewmates get one line in the generated brief: consult the brain before investigating (e.g. `gbrain search "<topic>"` / `gbrain think "<question>"`). This avoids attaching gbrain's 30+ MCP tool schemas to every worker context - the exact context bloat this epic is fighting
- **Primary (firstmate) options**, decided in this story: plain CLI via Bash (recommended default), or a trimmed MCP toolset (search/think/capture only) if tool-call ergonomics prove better in practice
- Retrieval guidance also belongs in the intake contract: before commissioning an investigation, firstmate consults existing reports *and the brain* ("consult existing reports and established evidence", AGENTS.md §7)

#### Scope

- [ ] Add the brain-consult line to `bin/fm-brief.sh` scaffolds (ship + scout variants), presence-gated: only rendered when the brain is configured in this home
- [ ] Document the retrieval commands and when to use `search` (raw pages) vs `think` (synthesized, cited, slower) in `docs/`
- [ ] Decide + implement the primary's access path (CLI vs trimmed MCP); record the decision and rationale
- [ ] Update AGENTS.md §7 intake wording to include brain consultation among established evidence (one-line change, keep the contract concise)
- [ ] Ship through the normal firstmate PR path

#### Acceptance criteria

- A freshly scaffolded brief in a brain-enabled home contains the consult instruction; a home without gbrain scaffolds identically to today
- A crewmate can run the consult command inside its worktree without extra setup
- Measured context cost of the chosen primary path documented (tokens added per session)

---

### Story 5: Brain scoping and secondmate inheritance policy

**Title:** gbrain 5/6: Per-home brain scoping and read-only main-brain sharing for secondmates

**Body:**

Part of the gbrain memory epic. Depends on stories 2-4.

**Suggested dispatch:** claude (Opus), xhigh effort - ambiguous design across FM_HOME isolation and secondmate provisioning.

#### Design

Secondmate homes are deliberately isolated (`FM_HOME` selects private `data/`, `state/`, `config/`). The brain follows the same shape:

- **One brain per `FM_HOME`** - each secondmate's captures stay in its own brain
- **Main brain shared read-only** to secondmates via gbrain's HTTP thin-client mode (bearer token), mirroring the `captain-shared.md` propagation pattern: secondmates can consult fleet-wide knowledge but only the main home writes to it
- Config lives in each home's local (gitignored) config, following the existing `config/*` conventions in `docs/configuration.md`; inheritance handled under the `secondmate-provisioning` contract

#### Scope

- [ ] Define the config file(s) (e.g. `config/brain` with endpoint/scope data), document in `docs/configuration.md` (single owner of config schemas)
- [ ] Main-home gbrain serves MCP-over-HTTP (localhost-only; secondmates are on the same box) with a bearer token; token stored in local config, never tracked
- [ ] Secondmate provisioning propagates the read-only client config as inherited local material (`secondmate-provisioning` skill owns the push path)
- [ ] Story-3 capture helper reads the home's own brain config, so secondmate captures land in the secondmate brain automatically
- [ ] Ship through the normal firstmate PR path

#### Acceptance criteria

- A secondmate can `search`/`think` against the main brain but a write attempt is refused
- A secondmate's own captures are not visible from the main brain
- Fresh secondmate seeding produces a working brain client config with no manual steps beyond token provisioning

---

### Story 6: Evaluation, migration playbook, and dream-cycle decision

**Title:** gbrain 6/6: Retrieval quality evaluation, embedding-migration playbook, dream-cycle go/no-go

**Body:**

Part of the gbrain memory epic. Depends on stories 1-4 running for at least a couple of weeks of real fleet work.

**Suggested dispatch:** claude (Opus), xhigh effort - scout-type investigation and judgment-heavy decisions.

#### Scope

- [ ] **Retrieval eval:** ~20 real questions from fleet history ("what did the X scout conclude", "have we hit this bug before") scored for top-5 hit rate on `search` and answer quality on `think`, with the story-1 model (arctic-embed-l-v2 @1024d)
- [ ] If quality disappoints: re-run the eval after `gbrain reinit-pglite --embedding-model ollama:qwen3-embed-8b --embedding-dimensions 4096` (local re-embed is cheap on the rig); keep whichever wins; record the numbers
- [ ] **Migration playbook:** document the exact reinit/re-embed procedure and its cost, so future model swaps are routine (upstream: `docs/embedding-migrations.md` for the Postgres path)
- [ ] **Dream-cycle go/no-go:** gbrain's overnight enrichment (dedup, citation fixes, salience scoring, contradiction finding) requires an LLM; local support is unconfirmed upstream. Investigate whether it can run against a local model (GPUs 2-3 have 32GB free - e.g. Qwen3-14B/32B quant via Ollama, possibly through gbrain's LiteLLM-proxy recipe). Ship a recommendation: enable locally / enable with a cheap cloud model / skip
- [ ] **Upgrade policy:** document how/when to move the version pin (upstream is fast-moving)

#### Acceptance criteria

- Eval results recorded with numbers, and a model decision made and applied
- Migration playbook tested at least once end to end
- Dream-cycle decision recorded with rationale (including cost and privacy notes if any cloud model is involved)
