# Epic 2: Firstmate fleet dashboard (kanban + decisions + tokens + live events)

## Epic

**Title:** Epic: Locally-hosted fleet dashboard - kanban board, decisions inbox, token usage, live agent events

**Body:**

### Problem

Firstmate runs workers across Claude Code, Codex, opencode, and pi inside tmux on a headless homelab server. There is no way to see at a glance what the fleet is doing, which tasks need the captain's decision, or what the token burn is - especially from a phone over Twingate, where the only interface today is Termius -> SSH -> herdr/tmux.

### Goal

A locally-hosted, phone-friendly web dashboard: kanban board of all fleet work filterable by project/harness/state, a "needs you" inbox for decisions and green PRs, per-task/per-project/per-harness token usage, and (later) a live event timeline per agent.

### Architecture decisions (from research)

- **Do not adopt an agent-manager product** (Vibe Kanban, claude-squad, crystal, omnara): they own agent dispatch and lifecycle, which would compete with firstmate's spawn/supervision machinery. The dashboard is **strictly read-only over firstmate's own state** in phase 1.
- **The data model already exists:** `bin/fm-fleet-snapshot.sh --json` emits the stable versioned `fm-fleet-snapshot.v1` schema - per-task reconciled current state, kind, project, harness/backend/model, endpoint liveness, PR URL, pending-decision hints (`hints.pending_decision`, `hints.open_decisions`, `captain_actionable`), full backlog with blockers, secondmate roll-ups, scout report pointers. Its header contract says human views must render this output rather than re-parsing state files - the dashboard is exactly such a renderer.
- **Token/event layer joins on `state/<id>.meta`:** each task records `worktree=`, `window=`, `project=`, `harness=`, `model=` - the join key that attributes each harness's transcripts/telemetry to a task card. This is the piece no off-the-shelf tool has.
- **Event/token sources per harness:** Claude Code hooks + `~/.claude/projects` JSONL (ccusage-style parsing) or built-in OTEL; Codex `notify`/hooks + built-in OTEL (`[otel]` in `~/.codex/config.toml`); opencode plugin event bus (existing token plugins); pi via the pi-agent-observability extension pattern (disler's Bun+SQLite+SSE stack, MIT).
- **Stack:** small Bun (or Python) server on the homelab; snapshot poll + fs-watch on `state/`; SSE to a single-page UI; SQLite for the event/token store. Bound to the Twingate-reachable interface with basic auth.

### Stories and dispatch plan

| # | Story | Harness / model | Effort | Why |
|---|---|---|---|---|
| 1 | Kanban dashboard MVP over `fm-fleet-snapshot.v1` | codex | high | Large, well-specified greenfield build (server + SPA) - prime Codex territory |
| 2 | "Needs you" inbox and fleet health signals | claude / Sonnet | medium | Needs correct reading of firstmate state semantics; UI itself is simple |
| 3 | Per-harness token usage collectors joined to tasks | codex | high | Fiddly multi-format data engineering, fully specified |
| 4 | Live agent event stream (hooks per harness) | claude / Opus | high | Wires into Claude Code's own hook system inside crew spawn env without breaking firstmate guards |
| 5 | Remote access hardening + ttyd click-through | codex | medium | Well-understood ops/security configuration |
| 6 | History browser: done tasks, PRs, scout reports | codex | low | Simple read-only views; bump to medium if sanitized rendering gets involved |

Rationale: Codex ($100 sub) takes the bounded implementation volume; Claude ($200 sub) takes the stories requiring firstmate-internals judgment, and its larger allowance also funds primary supervision. Per-task overrides remain the captain's call at dispatch time.

### Epic acceptance criteria

- [ ] Board reachable from the phone over Twingate showing live fleet state grouped by state, filterable by project and harness
- [ ] Decisions/green-PR inbox surfaces every `captain_actionable` item with age
- [ ] Token usage visible per task, project, and harness for at least Claude Code + one other harness
- [ ] Dashboard is read-only against fleet state; killing it has zero effect on supervision
- [ ] Runs as a persistent service on the homelab, surviving reboot

### Non-goals (phase 1)

- Any write path (approve/deny, steering) from the web UI - phase 2, requires auth hardening and careful sequencing with the live supervision session via `fm-send`
- Replacing herdr/tmux for actual interactive work
- Cloud hosting of any component

### References

- Snapshot contract: `bin/fm-fleet-snapshot.sh` (schema `fm-fleet-snapshot.v1`), renderer example `bin/fm-fleet-view.sh`
- Task metadata: `state/<id>.meta` fields per AGENTS.md §2
- disler observability stack: https://github.com/disler/claude-code-hooks-multi-agent-observability and https://github.com/disler/pi-agent-observability (MIT)
- ccusage: https://github.com/ryoppippi/ccusage ; Codex OTEL: https://signoz.io/docs/codex-monitoring/ ; opencode token plugins: https://github.com/Ainsley0917/opencode-token-monitor , https://github.com/ramtinJ95/opencode-tokenscope
- ttyd: https://github.com/tsl0922/ttyd

---

### Story 1: Kanban dashboard MVP over fm-fleet-snapshot.v1

**Title:** dashboard 1/6: Read-only kanban board served from fm-fleet-snapshot.v1

**Body:**

Part of the fleet dashboard epic. The MVP: a board that renders what the fleet is doing right now.

**Suggested dispatch:** codex, high effort - large, well-specified greenfield build.

#### Design

- Server (Bun or Python, single process): every 10-15s - or on fs events under `state/` and `data/backlog.md`, debounced - run `bin/fm-fleet-snapshot.sh --json`, diff against the last snapshot, push changes over SSE. Serve the SPA statically. Read-only by construction: the only fleet interaction is executing the snapshot script, which is documented read-only (no lock, no wake drain, no mutation).
- Columns from reconciled state: Queued / In flight / Needs decision / PR open / Done (recent). Map from `tasks[].current_state` + backlog records; `hints.pending_decision` and `captain_actionable` drive the Needs-decision column.
- Card contents: task id/title, project, kind (ship/scout/secondmate), harness+model, current state detail, PR URL (full https link), endpoint liveness dot, age since last status event.
- Filters: project, harness, kind, state. Mobile-first layout (this will be used from a phone).
- Secondmates render as a separate always-on lane (they are persistent, never backlog items), using the snapshot's `secondmate_current` records.

#### Scope

- [ ] Server with snapshot poll/watch + SSE + static SPA serving; config via env/flags (FM_HOME, port, poll interval)
- [ ] Board UI with the columns, cards, and filters above; dark-mode-friendly; usable at phone width
- [ ] Graceful states: snapshot script missing/erroring, empty fleet, stale data indicator (last-refresh age)
- [ ] systemd unit for boot persistence
- [ ] Location decision: new top-level `dashboard/` in the firstmate repo (shared tracked material -> normal PR path + `firstmate-coding-guidelines`) vs. separate repo; record rationale

#### Acceptance criteria

- With live fleet work under way, the board reflects a state change (e.g. task goes needs-decision) within one poll interval with no reload
- Zero writes under `data/`, `state/`, `projects/` from the dashboard process (verify with strace or fs-watch during a session)
- Works in a phone browser over the Twingate network

---

### Story 2: "Needs you" inbox and fleet health signals

**Title:** dashboard 2/6: Captain inbox (decisions, green PRs, blockers) + fleet health strip

**Body:**

Part of the fleet dashboard epic. Depends on story 1. This is the highest-value screen for away-from-desk use.

**Suggested dispatch:** claude (Sonnet), medium effort - correct reading of firstmate state semantics matters more than UI volume.

#### Design

Inbox items, sorted by age, each with enough context to act on and deep links:

| Item | Source in snapshot |
|---|---|
| Decision needed (ask-user finding, captain hold) | `hints.open_decisions`, backlog `captain_actionable`, `hold_kind`/`hold_reason` |
| PR green, awaiting merge word | task `pr.url` + state; meta `pr=` |
| Real blocker / failure | current_state failed states, `blocked_by`+`blocked_reason` |
| Credential/login needed | status open-decision keys of that class |

Health strip (machinery, not tasks): watcher liveness (`state/.last-watcher-beat` age), afk flag (`state/.afk`), per-task last-event age with a staleness threshold, secondmate endpoint liveness (`endpoint.exists` / `agent_alive`), orphan detection (meta without live endpoint).

#### Scope

- [ ] Inbox view with age-sorted actionable items and full PR URLs
- [ ] Health strip with green/amber/red states and tooltips explaining each signal
- [ ] Badge counts in the board header (n decisions, n green PRs, n blockers)
- [ ] Optional: browser notifications on new inbox items (client-side only)

#### Acceptance criteria

- A task entering needs-decision appears in the inbox within one poll interval, with the decision text visible
- A green PR shows its full https URL, clickable from the phone
- Killing the watcher makes the health strip go red within its threshold

---

### Story 3: Per-harness token usage collectors joined to tasks

**Title:** dashboard 3/6: Token/cost collectors for claude, codex, opencode, pi - joined to tasks via state/<id>.meta

**Body:**

Part of the fleet dashboard epic. Depends on story 1 (dashboard exists to display it). Independent of stories 2/4.

**Suggested dispatch:** codex, high effort - fiddly multi-format data engineering, fully specified.

#### Design

Interval collectors (cron or server-internal timer) parse each harness's local usage records into one SQLite table `usage(ts, harness, session_ref, task_id, project, model, input_tokens, output_tokens, cache_tokens, cost_estimate)`. Attribution: resolve each harness session to a task by matching session cwd against `state/<id>.meta` `worktree=` (fallback: window/time correlation). Unattributed usage still aggregates under harness/project=unknown.

Per-harness sources:

| Harness | Source | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` transcripts (ccusage-style parsing; ccusage has JSON output usable directly) | cwd in transcript -> worktree join |
| Codex | `[otel]` metrics exporter in `~/.codex/config.toml` -> local OTLP receiver, or `notify`/`postTaskComplete` hook writing session JSON | prefer hook for simplicity, OTEL if already running a collector |
| opencode | session SQLite / plugin (`opencode-token-monitor`, `tokenscope`) emitting per-message token events | plugin route also feeds story 4 |
| pi | pi-agent-observability extension events (tokens per turn) | shares story 4 plumbing |

Start with Claude Code (biggest share, easiest source) + one more; grok/cursor/agy fall back to no token data.

#### Scope

- [ ] SQLite schema + collector framework with per-harness adapters; idempotent re-parsing (no double counting)
- [ ] Claude Code adapter (JSONL parsing incl. cache tokens; model-aware cost table)
- [ ] Codex adapter (hook or OTLP)
- [ ] opencode and pi adapters (may land as follow-ups; keep the interface ready)
- [ ] Dashboard views: tokens/cost per task card; rollups by project, harness, day; burn-rate sparkline for the last hour
- [ ] Attribution accuracy check documented (what fraction of usage matched a task)

#### Acceptance criteria

- A completed Claude Code task shows total tokens and estimated cost on its card, matching ccusage's numbers for the same session within rounding
- Project and harness rollups sum consistently with per-task numbers
- Collectors survive malformed/rotated transcript files without crashing

---

### Story 4: Live agent event stream

**Title:** dashboard 4/6: Live event timeline per agent (hooks/plugins per harness -> SQLite -> SSE)

**Body:**

Part of the fleet dashboard epic. Depends on story 1; shares storage with story 3. This layer answers "what is that agent actually doing right now" without attaching to tmux.

**Suggested dispatch:** claude (Opus), high effort - wires into Claude Code's own hook system inside the crew spawn environment without breaking firstmate guards.

#### Design

Adopt the disler observability pattern (agent lifecycle hooks -> `POST /events` -> SQLite -> SSE -> timeline UI), extended with the task join:

- **Claude Code:** hooks (PreToolUse, PostToolUse, Notification, Stop, SubagentStart/Stop, UserPromptSubmit...) POSTing to the dashboard server; hook config ships in the worker environment, tagged with task id from the environment/cwd. Reference implementation: https://github.com/disler/claude-code-hooks-multi-agent-observability (Bun+SQLite+Vue; license unspecified - treat as pattern reference, implement our own thin version)
- **pi:** port the extension from https://github.com/disler/pi-agent-observability (MIT) - same event server contract
- **Codex:** `notify` hooks for lifecycle events (turn/task completion); finer-grained via OTEL logs if a collector is running
- **opencode:** plugin subscribing to the event bus (`message.updated`, tool events) POSTing the same schema
- Event schema: `(ts, task_id, harness, session_ref, event_type, payload_json)` - one table, one SSE channel, filterable

UI: per-task timeline drawer from the kanban card (story 1), plus an all-agents swimlane view. Show tool calls with truncated args, state transitions, decision prompts.

#### Scope

- [ ] `POST /events` endpoint + SQLite event store + SSE broadcast on the story-1 server
- [ ] Claude Code hook set wired into crew spawn environment (must not interfere with firstmate's existing hooks/guards - additive only, and removable via config)
- [ ] pi extension port; codex notify hook; opencode plugin (any may land as follow-ups behind the shared endpoint)
- [ ] Timeline + swimlane UI with event-type filtering
- [ ] Retention policy (size-capped DB, prune oldest)

#### Acceptance criteria

- Watching a live task's timeline shows tool calls appearing in near-real-time
- A harness without instrumentation degrades gracefully (card still works, timeline says "no event source")
- Removing the hook config restores stock harness behavior

---

### Story 5: Remote access hardening + tmux pane click-through

**Title:** dashboard 5/6: Twingate-friendly serving, auth, and read-only ttyd deep links into task panes

**Body:**

Part of the fleet dashboard epic. Depends on story 1.

**Suggested dispatch:** codex, medium effort - well-understood ops/security configuration.

#### Scope

- [ ] Bind dashboard to the Twingate-reachable interface; TLS (self-signed or internal CA) or an SSH-tunnel-only stance - decide and document
- [ ] Authentication: basic auth minimum (secrets in local gitignored config, never tracked); rate-limit auth failures
- [ ] [ttyd](https://github.com/tsl0922/ttyd) in **read-only mode** attached per request to a task's tmux window (from meta `window=`), so a kanban card can deep-link to a live view of the actual pane from the phone; write mode explicitly out of scope (phase 2)
- [ ] Confirm the phone flow end to end: Twingate on -> dashboard URL -> card -> live pane view, no Termius needed for a look-see
- [ ] systemd units; document ports and firewall posture

#### Acceptance criteria

- Dashboard and pane view reachable from the phone with Twingate on, unreachable with it off
- ttyd sessions cannot inject input (verified)
- No secrets in tracked files

---

### Story 6: History browser - done tasks, PRs, scout reports

**Title:** dashboard 6/6: Browse completed work - done tasks, merged PRs, rendered scout reports

**Body:**

Part of the fleet dashboard epic. Depends on story 1. Pairs with the gbrain memory epic (the dashboard shows recent history; the brain answers deep questions).

**Suggested dispatch:** codex, low effort (bump to medium if sanitized rendering grows involved).

#### Scope

- [ ] Done view from backlog Done records + retained metadata: task title, project, completion date, PR URL, report link
- [ ] Scout report browser: render `data/<id>/report.md` as HTML (sanitized markdown rendering; reports are trusted-ish local files but render defensively)
- [ ] Per-project history filter and simple text search over titles/reports
- [ ] If the gbrain epic has landed: a search box that shells to `gbrain search` for semantic lookup across archived knowledge (presence-gated)
- [ ] Token/cost totals per completed task when story 3 data exists

#### Acceptance criteria

- A completed scout's report is readable, formatted, from the phone
- Done tasks show full PR URLs
- Views degrade gracefully when backlog retention has pruned older Done entries
