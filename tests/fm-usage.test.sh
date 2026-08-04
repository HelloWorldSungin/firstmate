#!/usr/bin/env bash
# Behavior tests for the usage store, the Claude and Codex collectors, durable
# task attribution across teardown, and the read-only rollups.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE_BIN="$ROOT/bin/fm-usage.mjs"
MANIFEST="$ROOT/bin/fm-outcome-manifest.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null \
  || { echo "skip: node:sqlite not available (Node 22+ required)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-usage)
export TZ=UTC

# --- fixtures ---------------------------------------------------------------
#
# Both fixture writers reproduce the exact line shapes the real harnesses emit,
# including the details that make naive collectors wrong: Claude writes one API
# response to several transcript lines with the same message id, and Codex
# reports cumulative session totals rather than per-turn deltas.

# claude_line <file> <session> <cwd> <ts> <message-id> <in> <out> <cache-read> <cache-write>
claude_line() {
  local file=$1 session=$2 cwd=$3 ts=$4 mid=$5 in=$6 out=$7 cread=$8 cwrite=$9
  jq -cn --arg session "$session" --arg cwd "$cwd" --arg ts "$ts" --arg mid "$mid" \
    --argjson in "$in" --argjson out "$out" --argjson cread "$cread" --argjson cwrite "$cwrite" \
    '{type:"assistant",uuid:($mid + "-" + ($ts|tostring)),sessionId:$session,cwd:$cwd,
      timestamp:$ts,requestId:("req_" + $mid),
      message:{id:$mid,model:"claude-opus-5",role:"assistant",
               content:[{type:"text",text:"SECRET_ASSISTANT_PROSE"}],
               usage:{input_tokens:$in,output_tokens:$out,
                      cache_read_input_tokens:$cread,
                      cache_creation_input_tokens:$cwrite}}}' >> "$file"
}

# claude_noise <file> <session> <cwd>: the non-usage lines a real transcript is
# mostly made of, including a user prompt and a tool call carrying sentinels.
claude_noise() {
  local file=$1 session=$2 cwd=$3
  jq -cn --arg session "$session" --arg cwd "$cwd" \
    '{type:"user",sessionId:$session,cwd:$cwd,timestamp:"2026-08-01T00:00:00Z",
      message:{role:"user",content:[{type:"text",text:"SECRET_USER_PROMPT and TOKEN_ghp_SECRETCREDENTIAL"}]}}' >> "$file"
  jq -cn --arg session "$session" --arg cwd "$cwd" \
    '{type:"assistant",sessionId:$session,cwd:$cwd,timestamp:"2026-08-01T00:00:01Z",
      message:{id:"msg_toolcall",role:"assistant",
               content:[{type:"tool_use",name:"Bash",input:{command:"echo SECRET_TOOL_ARGUMENT"}}]}}' >> "$file"
}

# codex_rollout <file> <session> <cwd> <model>: header lines only.
codex_rollout() {
  local file=$1 session=$2 cwd=$3 model=$4
  jq -cn --arg session "$session" --arg cwd "$cwd" \
    '{timestamp:"2026-08-01T00:00:00Z",type:"session_meta",
      payload:{session_id:$session,cwd:$cwd,cli_version:"0.145.0",
               base_instructions:{text:"SECRET_CODEX_INSTRUCTIONS"}}}' > "$file"
  jq -cn --arg cwd "$cwd" --arg model "$model" \
    '{timestamp:"2026-08-01T00:00:01Z",type:"turn_context",
      payload:{cwd:$cwd,model:$model,turn_id:"t1"}}' >> "$file"
  jq -cn '{timestamp:"2026-08-01T00:00:02Z",type:"response_item",
      payload:{type:"message",role:"user",
               content:[{type:"input_text",text:"SECRET_CODEX_PROMPT"}]}}' >> "$file"
}

# codex_token_count <file> <ts> <cum-in> <cum-out> <cum-cached> <cum-reasoning>
codex_token_count() {
  local file=$1 ts=$2 in=$3 out=$4 cached=$5 reasoning=$6
  jq -cn --arg ts "$ts" --argjson in "$in" --argjson out "$out" \
    --argjson cached "$cached" --argjson reasoning "$reasoning" \
    '{timestamp:$ts,type:"event_msg",
      payload:{type:"token_count",
               info:{total_token_usage:{input_tokens:$in,output_tokens:$out,
                                        cached_input_tokens:$cached,
                                        cache_write_input_tokens:0,
                                        reasoning_output_tokens:$reasoning,
                                        total_tokens:($in + $out)},
                     last_token_usage:{input_tokens:$in,output_tokens:$out,
                                       cached_input_tokens:$cached,
                                       cache_write_input_tokens:0,
                                       reasoning_output_tokens:$reasoning,
                                       total_tokens:($in + $out)},
                     model_context_window:258400},
               rate_limits:{primary:{used_percent:12}}}}' >> "$file"
}

# new_case <name>: a fresh operational home plus empty source roots.
new_case() {
  local case_root="$TMP_ROOT/$1"
  mkdir -p "$case_root/home/state" "$case_root/home/data" "$case_root/home/config" \
    "$case_root/claude" "$case_root/codex/2026/08/01"
  printf '%s\n' "$case_root"
}

# usage_run <case-root> <subcommand...>
usage_run() {
  local case_root=$1
  shift
  FM_USAGE_NOW=${FM_USAGE_NOW:-2026-08-01T12:00:00Z} \
  node "$USAGE_BIN" "$1" --home "$case_root/home" \
    --claude-root "$case_root/claude" --codex-root "$case_root/codex" "${@:2}"
}

# write_meta_at <file> <mtime> <key=value...>: task metadata with a pinned mtime,
# which is what the collector reads as the task's start.
write_meta_at() {
  local file=$1 mtime=$2
  shift 2
  fm_write_meta "$file" "$@"
  touch -t "$mtime" "$file"
}

# --- Claude adapter ---------------------------------------------------------

test_claude_adapter() {
  local case_root
  case_root=$(new_case claude-adapter)
  local dir="$case_root/claude/-home-worker-alpha"
  mkdir -p "$dir"
  local file="$dir/session-a.jsonl"
  : > "$file"
  claude_noise "$file" session-a /home/worker/alpha
  claude_line "$file" session-a /home/worker/alpha 2026-08-01T10:00:00Z msg_one 10 200 3000 500
  # The same API response, written three times exactly as Claude Code does.
  claude_line "$file" session-a /home/worker/alpha 2026-08-01T10:00:01Z msg_two 5 100 1000 0
  claude_line "$file" session-a /home/worker/alpha 2026-08-01T10:00:02Z msg_two 5 100 1000 0
  claude_line "$file" session-a /home/worker/alpha 2026-08-01T10:00:03Z msg_two 5 100 1000 0

  local out
  out=$(usage_run "$case_root" ingest) || fail "claude ingest failed"
  [ "$(jq -r '.collected.events_new' <<<"$out")" = 2 ] \
    || fail "claude adapter should store one event per API response, got $(jq -r '.collected.events_new' <<<"$out")"

  local row
  row=$(usage_run "$case_root" report --by harness | jq -c '.rows[] | select(.key == "claude")')
  [ "$(jq -r '.input_tokens' <<<"$row")" = 15 ] || fail "claude input tokens wrong: $row"
  [ "$(jq -r '.output_tokens' <<<"$row")" = 300 ] || fail "claude output tokens wrong: $row"
  [ "$(jq -r '.cache_read_tokens' <<<"$row")" = 4000 ] || fail "claude cache read tokens wrong: $row"
  [ "$(jq -r '.cache_write_tokens' <<<"$row")" = 500 ] || fail "claude cache write tokens wrong: $row"
  # Claude reports the three input buckets as disjoint, so the total is their
  # sum plus output and no token is counted twice.
  [ "$(jq -r '.total_tokens' <<<"$row")" = 4815 ] || fail "claude total tokens wrong: $row"
  pass "the Claude adapter stores input, output, and cache tokens once per API response"
}

# --- Codex adapter ----------------------------------------------------------

test_codex_adapter() {
  local case_root
  case_root=$(new_case codex-adapter)
  local file="$case_root/codex/2026/08/01/rollout-2026-08-01T10-00-00-session-c.jsonl"
  codex_rollout "$file" session-c /home/worker/charlie gpt-5.6-sol
  codex_token_count "$file" 2026-08-01T10:00:10Z 1000 100 500 40
  codex_token_count "$file" 2026-08-01T10:00:20Z 3000 250 1500 90
  # A refresh that reports the same cumulative totals must add nothing.
  codex_token_count "$file" 2026-08-01T10:00:25Z 3000 250 1500 90

  usage_run "$case_root" ingest >/dev/null || fail "codex ingest failed"
  local row
  row=$(usage_run "$case_root" report --by harness | jq -c '.rows[] | select(.key == "codex")')
  # Codex counts its cached input INSIDE its input count, so the cached half
  # belongs in the cache column and not twice in the total. The store's columns
  # are disjoint whatever a harness reports.
  [ "$(jq -r '.input_tokens' <<<"$row")" = 1500 ] || fail "codex uncached input tokens wrong: $row"
  [ "$(jq -r '.output_tokens' <<<"$row")" = 250 ] || fail "codex output tokens wrong: $row"
  [ "$(jq -r '.cache_read_tokens' <<<"$row")" = 1500 ] || fail "codex cache read tokens wrong: $row"
  [ "$(jq -r '.reasoning_tokens' <<<"$row")" = 90 ] || fail "codex reasoning tokens wrong: $row"
  # Codex's own total for this session is input + output = 3250, with cached
  # input already inside input and reasoning already inside output.
  [ "$(jq -r '.total_tokens' <<<"$row")" = 3250 ] \
    || fail "the stored total must match the harness's own total: $row"
  [ "$(jq -r '.events' <<<"$row")" = 2 ] || fail "a repeated cumulative report must not add an event: $row"
  local model
  model=$(usage_run "$case_root" report --by model | jq -r '.rows[0].key')
  [ "$model" = "gpt-5.6-sol" ] || fail "codex model provenance wrong: $model"
  pass "the Codex adapter stores cumulative session growth without repeating a turn"
}

# --- Idempotence ------------------------------------------------------------

test_reprocessing_is_idempotent() {
  local case_root
  case_root=$(new_case idempotent)
  local dir="$case_root/claude/-home-worker-bravo"
  mkdir -p "$dir"
  claude_line "$dir/session-b.jsonl" session-b /home/worker/bravo 2026-08-01T10:00:00Z msg_a 10 20 30 40
  claude_line "$dir/session-b.jsonl" session-b /home/worker/bravo 2026-08-01T10:01:00Z msg_b 1 2 3 4
  local file="$case_root/codex/2026/08/01/rollout-session-d.jsonl"
  codex_rollout "$file" session-d /home/worker/delta gpt-5.6-sol
  codex_token_count "$file" 2026-08-01T10:00:10Z 500 50 100 10

  usage_run "$case_root" ingest >/dev/null || fail "first ingest failed"
  local first
  first=$(usage_run "$case_root" report --by harness | jq -Sc '.rows')

  local again
  again=$(usage_run "$case_root" ingest) || fail "second ingest failed"
  [ "$(jq -r '.collected.events_new' <<<"$again")" = 0 ] \
    || fail "an unchanged rescan must store no new events: $(jq -c '.collected' <<<"$again")"

  # A touched source is re-read in full; identity, not file position, is what
  # keeps the totals right.
  touch "$dir/session-b.jsonl"
  local touched
  touched=$(usage_run "$case_root" ingest) || fail "third ingest failed"
  [ "$(jq -r '.collected.events_new' <<<"$touched")" = 0 ] \
    || fail "re-reading a source must not duplicate its events"
  [ "$(jq -r '.collected.events_duplicate' <<<"$touched")" -ge 2 ] \
    || fail "re-reading a source should report its events as already stored"

  # A wiped store rebuilt from the same sources reproduces the same totals,
  # which is the restart and overlapping-window case.
  rm -f "$case_root/home/data/usage.db" "$case_root/home/data/usage.db-wal" \
    "$case_root/home/data/usage.db-shm"
  usage_run "$case_root" ingest >/dev/null || fail "rebuild ingest failed"
  local rebuilt
  rebuilt=$(usage_run "$case_root" report --by harness | jq -Sc '.rows')
  [ "$rebuilt" = "$first" ] || fail "a rebuilt store must reproduce the same totals"$'\n'"$first"$'\n'"$rebuilt"
  pass "reprocessing the same sources produces no duplicate usage"
}

# Collector windows overlap in the real fleet: an operator or a scheduler runs
# ingest on a cadence while teardown calls the collector best-effort for the task
# it is about to archive. The hardest moment is the FIRST overlap, when the store
# itself still has to be created - a collector that loses that race has to wait
# for the store rather than exit with a bare lock error and no usage collected.
test_overlapping_collector_windows() {
  local case_root
  case_root=$(new_case concurrent)
  local dir="$case_root/claude/-home-worker-race"
  mkdir -p "$dir"
  local index
  for index in $(seq 1 30); do
    claude_line "$dir/session-r.jsonl" session-r /home/worker/race \
      "2026-08-01T10:$(printf '%02d' "$index"):00Z" "msg_r$index" 1 2 3 4
  done
  local rollout="$case_root/codex/2026/08/01/rollout-session-r.jsonl"
  codex_rollout "$rollout" session-rc /home/worker/race gpt-5.6-sol
  codex_token_count "$rollout" 2026-08-01T10:00:10Z 500 50 100 10

  # What one collector stores when nothing competes with it.
  usage_run "$case_root" ingest --db "$case_root/sequential.db" >/dev/null \
    || fail "the sequential baseline ingest failed"
  local sequential
  sequential=$(usage_run "$case_root" report --db "$case_root/sequential.db" --by harness | jq -Sc '.rows')

  # Three collectors open the same not-yet-created store at the same moment.
  local pids=()
  for index in 1 2 3; do
    usage_run "$case_root" ingest >"$case_root/race-$index.json" 2>"$case_root/race-$index.err" &
    pids+=("$!")
  done
  for index in 1 2 3; do
    wait "${pids[$((index - 1))]}" \
      || fail "an overlapping collector window failed: $(cat "$case_root/race-$index.err")"
    [ ! -s "$case_root/race-$index.err" ] \
      || fail "an overlapping collector window complained: $(cat "$case_root/race-$index.err")"
    [ "$(jq -c '.failures' "$case_root/race-$index.json")" = '[]' ] \
      || fail "an overlapping collector window reported stage failures: $(jq -c '.failures' "$case_root/race-$index.json")"
  done

  # Overlapping windows converge on exactly what one collector alone stores:
  # every event once, the same totals, nothing lost and nothing doubled.
  local raced
  raced=$(usage_run "$case_root" report --by harness | jq -Sc '.rows')
  [ "$raced" = "$sequential" ] \
    || fail "overlapping windows must converge on the sequential result"$'\n'"$sequential"$'\n'"$raced"
  local settled
  settled=$(usage_run "$case_root" ingest) || fail "the settling ingest failed"
  [ "$(jq -r '.collected.events_new' <<<"$settled")" = 0 ] \
    || fail "the raced store must already hold every event: $(jq -c '.collected' <<<"$settled")"
  pass "overlapping collector windows converge instead of failing on a locked store"
}

test_malformed_and_rotated_sources() {
  local case_root
  case_root=$(new_case rotation)
  local dir="$case_root/claude/-home-worker-echo"
  mkdir -p "$dir"
  local file="$dir/session-e.jsonl"
  claude_line "$file" session-e /home/worker/echo 2026-08-01T10:00:00Z msg_keep 100 200 300 400
  usage_run "$case_root" ingest >/dev/null || fail "baseline ingest failed"
  local baseline
  baseline=$(usage_run "$case_root" report --by harness | jq -r '.rows[0].total_tokens')

  # Malformed, truncated, and empty lines around a good one.
  printf '{"type":"assistant","message":{"usage":\n' >> "$file"
  printf 'not json at all\n\n' >> "$file"
  # A well-formed line that IS a usage record but whose timestamp the adapter
  # cannot read: a field the harness changed, not a parse failure. It has its own
  # counter, so a harness that renames a field can never report zero new events,
  # zero malformed lines, and look like a quiet fleet.
  jq -cn '{type:"assistant",uuid:"u-skip",sessionId:"session-e",cwd:"/home/worker/echo",
           timestamp:"08/01/2026 10:06",
           message:{id:"msg_unreadable",model:"claude-opus-5",
                    usage:{input_tokens:9,output_tokens:9,
                           cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' >> "$file"
  claude_line "$file" session-e /home/worker/echo 2026-08-01T10:05:00Z msg_after 1 1 1 1
  local out
  out=$(usage_run "$case_root" ingest) || fail "ingest must survive malformed input"
  [ "$(jq -r '.collected.malformed_lines' <<<"$out")" -ge 2 ] \
    || fail "malformed lines must be reported: $(jq -c '.collected' <<<"$out")"
  [ "$(jq -r '.collected.events_skipped' <<<"$out")" -ge 1 ] \
    || fail "a usage record dropped by a field check must be counted: $(jq -c '.collected' <<<"$out")"

  # Rotation: the live transcript is moved aside and a fresh one takes its name.
  mv "$file" "$dir/session-e.1.jsonl"
  claude_line "$file" session-e2 /home/worker/echo 2026-08-01T11:00:00Z msg_rotated 5 5 5 5
  usage_run "$case_root" ingest >/dev/null || fail "ingest must survive rotation"

  # Truncation: the file shrinks under the collector.
  : > "$dir/session-e.1.jsonl"
  usage_run "$case_root" ingest >/dev/null || fail "ingest must survive truncation"

  local final
  final=$(usage_run "$case_root" report --by harness | jq -r '.rows[0].total_tokens')
  [ "$final" -ge "$baseline" ] \
    || fail "rotation or truncation must never lower a stored total ($baseline -> $final)"
  local kept
  kept=$(usage_run "$case_root" report --by harness | jq -r '.rows[0].events')
  [ "$kept" = 3 ] || fail "expected the rotated, truncated history to keep 3 events, got $kept"
  pass "malformed, truncated, and rotated input cannot crash the collector or lose totals"
}

# --- Attribution ------------------------------------------------------------

test_live_attribution_and_session_map() {
  local case_root
  case_root=$(new_case live-attribution)
  local worktree="$case_root/worktrees/slot-1"
  mkdir -p "$worktree"
  write_meta_at "$case_root/home/state/alpha.meta" 202608010900.00 \
    "window=fm:alpha" "worktree=$worktree" "project=demo" "harness=claude" \
    "model=claude-opus-5" "effort=high" "kind=ship" "mode=no-mistakes"
  local dir="$case_root/claude/-slot-1"
  mkdir -p "$dir"
  claude_line "$dir/live.jsonl" session-live "$worktree" 2026-08-01T10:00:00Z msg_live 10 20 30 40

  local out
  out=$(usage_run "$case_root" ingest) || fail "live ingest failed"
  [ "$(jq -r '.sessions_bound' <<<"$out")" = 1 ] || fail "a live task's session must be bound"
  [ "$(jq -r '.task_session_maps_published' <<<"$out")" = 1 ] \
    || fail "the live session map must be published for the outcome manifest"

  local sidecar="$case_root/home/state/alpha.usage-sessions"
  assert_present "$sidecar" "the live session map should exist"
  [ "$(jq -r '.schema' "$sidecar")" = fm-usage-sessions.v1 ] || fail "session map schema wrong"
  [ "$(jq -r '.sessions[0].session_id' "$sidecar")" = session-live ] || fail "session map content wrong"

  local row
  row=$(usage_run "$case_root" report --by task | jq -c '.rows[] | select(.key == "alpha")')
  [ "$(jq -r '.total_tokens' <<<"$row")" = 100 ] || fail "live task totals wrong: $row"
  local method
  method=$(usage_run "$case_root" attribution | jq -r '.by_method[] | select(.method == "session_binding") | .confidence')
  [ "$method" = high ] || fail "a live worktree binding should report high confidence, got '$method'"
  pass "usage from a live task is attributed to it and its session map is published"
}

test_totals_survive_teardown() {
  local case_root
  case_root=$(new_case durable-attribution)
  local worktree="$case_root/worktrees/slot-2"
  mkdir -p "$worktree" "$case_root/home/data/bravo"
  printf 'brief\n' > "$case_root/home/data/bravo/brief.md"
  write_meta_at "$case_root/home/state/bravo.meta" 202608010900.00 \
    "window=fm:bravo" "worktree=$worktree" "project=demo" "harness=claude" \
    "model=claude-opus-5" "effort=high" "kind=ship" "mode=no-mistakes"
  printf 'done: PR https://example.invalid/pr/1 checks green\n' \
    > "$case_root/home/state/bravo.status"

  # A Claude session and a Codex session, both in the task's worktree.
  local dir="$case_root/claude/-slot-2"
  mkdir -p "$dir"
  claude_line "$dir/live.jsonl" session-claude "$worktree" 2026-08-01T10:00:00Z msg_c1 10 90 400 500
  local rollout="$case_root/codex/2026/08/01/rollout-session-codex.jsonl"
  codex_rollout "$rollout" session-codex "$worktree" gpt-5.6-sol
  codex_token_count "$rollout" 2026-08-01T10:02:00Z 2000 300 800 60

  usage_run "$case_root" ingest >/dev/null || fail "pre-teardown ingest failed"
  # 1000 from the Claude response plus 2300 from the Codex turn, whose 800
  # cached tokens are inside its 2000 input count rather than beside it.
  local before
  before=$(usage_run "$case_root" report --by task | jq -c '.rows[] | select(.key == "bravo")')
  [ "$(jq -r '.total_tokens' <<<"$before")" = 3300 ] || fail "pre-teardown totals wrong: $before"

  # Exactly what teardown does: publish the manifest from the records that still
  # exist, then remove the volatile ones.
  FM_HOME="$case_root/home" "$MANIFEST" write bravo >/dev/null || fail "manifest write failed"
  local manifest="$case_root/home/data/bravo/outcome.json"
  local carried
  carried=$(jq -r '[.attribution.sessions[].session_id] | sort | join(",")' "$manifest")
  [ "$carried" = "session-claude,session-codex" ] \
    || fail "the manifest must carry both harnesses' sessions, got '$carried'"
  FM_HOME="$case_root/home" "$MANIFEST" validate bravo >/dev/null \
    || fail "a manifest carrying sessions must validate"
  rm -f "$case_root/home/state/bravo.meta" "$case_root/home/state/bravo.status" \
    "$case_root/home/state/bravo.usage-sessions"

  # A store rebuilt from scratch after cleanup still knows whose tokens these are.
  rm -f "$case_root/home/data/usage.db" "$case_root/home/data/usage.db-wal" \
    "$case_root/home/data/usage.db-shm"
  usage_run "$case_root" ingest >/dev/null || fail "post-teardown ingest failed"
  local after
  after=$(usage_run "$case_root" report --by task | jq -c '.rows[] | select(.key == "bravo")')
  [ "$(jq -r '.total_tokens' <<<"$after")" = 3300 ] \
    || fail "a completed task must keep its token totals after teardown: $after"
  [ "$(jq -r '.sessions' <<<"$after")" = 2 ] || fail "both sessions must stay attributed: $after"
  local project
  project=$(usage_run "$case_root" report --by project | jq -r '.rows[] | select(.key == "demo") | .total_tokens')
  [ "$project" = 3300 ] || fail "project attribution must survive teardown, got $project"
  pass "completed Claude and Codex tasks retain their token totals after teardown"
}

# Treehouse hands the same pool slot to task after task, so a torn-down task's
# record must stop claiming that worktree once its live records are gone. The
# store is deliberately NOT wiped between the two tasks here: that is the path a
# real fleet takes, and the one a rebuilt-store case cannot see.
test_a_recycled_worktree_slot_belongs_to_the_task_holding_it() {
  local case_root
  case_root=$(new_case recycled-slot)
  local worktree="$case_root/worktrees/pool-slot"
  mkdir -p "$worktree" "$case_root/home/data/first"
  printf 'brief\n' > "$case_root/home/data/first/brief.md"
  write_meta_at "$case_root/home/state/first.meta" 202608010900.00 \
    "window=fm:first" "worktree=$worktree" "project=demo" "harness=claude" \
    "model=claude-opus-5" "effort=high" "kind=ship" "mode=no-mistakes"
  printf 'done: PR https://example.invalid/pr/1 checks green\n' \
    > "$case_root/home/state/first.status"
  local dir="$case_root/claude/-pool-slot"
  mkdir -p "$dir"
  claude_line "$dir/first.jsonl" session-first "$worktree" 2026-08-01T10:00:00Z msg_f1 10 20 30 40

  local out
  out=$(usage_run "$case_root" ingest) || fail "the first task's ingest failed"
  [ "$(jq -r '.sessions_bound' <<<"$out")" = 1 ] || fail "the first task's session must bind: $out"

  # Teardown of the first task: publish the manifest, then remove the volatile
  # records it was composed from.
  FM_HOME="$case_root/home" "$MANIFEST" write first >/dev/null || fail "manifest write failed"
  rm -f "$case_root/home/state/first.meta" "$case_root/home/state/first.status" \
    "$case_root/home/state/first.usage-sessions"

  # The pool hands the same slot to the next task, which opens its own session.
  write_meta_at "$case_root/home/state/second.meta" 202608011100.00 \
    "window=fm:second" "worktree=$worktree" "project=demo" "harness=claude" \
    "model=claude-opus-5" "effort=high" "kind=ship" "mode=no-mistakes"
  claude_line "$dir/second.jsonl" session-second "$worktree" 2026-08-01T11:30:00Z msg_s1 1 2 3 4

  out=$(usage_run "$case_root" ingest) || fail "the second task's ingest failed"
  [ "$(jq -r '.sessions_bound' <<<"$out")" = 1 ] \
    || fail "the task now holding the slot must bind its own session: $out"
  local sidecar="$case_root/home/state/second.usage-sessions"
  assert_present "$sidecar" "the new holder's session map must reach its own manifest"
  [ "$(jq -r '.sessions[0].session_id' "$sidecar")" = session-second ] \
    || fail "the new holder's session map carries the wrong session: $(cat "$sidecar")"

  local report attribution
  report=$(usage_run "$case_root" report --by task)
  attribution=$(usage_run "$case_root" attribution)
  [ "$(jq -r '.rows[] | select(.key == "first") | .total_tokens' <<<"$report")" = 100 ] \
    || fail "the torn-down task lost its own usage: $report"
  [ "$(jq -r '.rows[] | select(.key == "second") | .total_tokens' <<<"$report")" = 10 ] \
    || fail "usage in a recycled slot was not attributed to the task holding it: $report"
  [ "$(jq -r '[.by_method[] | select(.method == "ambiguous") | .events] | add // 0' <<<"$attribution")" = 0 ] \
    || fail "a recycled slot must not make either task's usage ambiguous: $attribution"
  pass "a recycled worktree slot attributes usage to the task holding it"
}

# Task ids are operator-supplied slugs and data/<id>/ outlives cleanup, so the
# same slug can be dispatched again after an earlier task of that name finished.
# A task row describes one occupancy: the new one must start its own window
# rather than inherit the closed one, or nothing it spends is ever attributed and
# its manifest archives the previous occupancy's session instead.
test_a_redispatched_task_id_starts_a_fresh_window() {
  local case_root
  case_root=$(new_case recycled-id)
  local worktree="$case_root/worktrees/slot-id"
  mkdir -p "$worktree" "$case_root/home/data/ship-login"
  printf 'brief\n' > "$case_root/home/data/ship-login/brief.md"
  local dir="$case_root/claude/-slot-id"
  mkdir -p "$dir"

  write_meta_at "$case_root/home/state/ship-login.meta" 202608010900.00 \
    "window=fm:ship-login" "worktree=$worktree" "project=demo" "harness=claude" \
    "model=claude-opus-5" "effort=high" "kind=ship" "mode=no-mistakes"
  printf 'done: PR https://example.invalid/pr/1 checks green\n' \
    > "$case_root/home/state/ship-login.status"
  claude_line "$dir/one.jsonl" session-run-one "$worktree" 2026-08-01T10:00:00Z msg_one 10 20 30 40
  usage_run "$case_root" ingest >/dev/null || fail "the first occupancy's ingest failed"

  FM_HOME="$case_root/home" "$MANIFEST" write ship-login >/dev/null || fail "manifest write failed"
  rm -f "$case_root/home/state/ship-login.meta" "$case_root/home/state/ship-login.status" \
    "$case_root/home/state/ship-login.usage-sessions"
  usage_run "$case_root" ingest >/dev/null || fail "the post-teardown ingest failed"

  # The operator dispatches the same slug again days later.
  write_meta_at "$case_root/home/state/ship-login.meta" 202608050900.00 \
    "window=fm:ship-login" "worktree=$worktree" "project=demo" "harness=claude" \
    "model=claude-opus-5" "effort=high" "kind=ship" "mode=no-mistakes"
  claude_line "$dir/two.jsonl" session-run-two "$worktree" 2026-08-05T10:00:00Z msg_two 1 2 3 4

  local out
  out=$(FM_USAGE_NOW=2026-08-05T12:00:00Z usage_run "$case_root" ingest) \
    || fail "the second occupancy's ingest failed"
  [ "$(jq -r '.sessions_bound' <<<"$out")" = 1 ] \
    || fail "a re-dispatched task id must bind its own session: $out"
  local sidecar="$case_root/home/state/ship-login.usage-sessions"
  assert_present "$sidecar" "the re-dispatched task must publish a session map"
  jq -e '[.sessions[].session_id] | index("session-run-two")' "$sidecar" >/dev/null \
    || fail "the session map must carry the running occupancy's session: $(cat "$sidecar")"

  local total unattributed
  total=$(usage_run "$case_root" report --by task \
    | jq -r '.rows[] | select(.key == "ship-login") | .total_tokens')
  [ "$total" = 110 ] || fail "both occupancies of the id must keep their usage, got $total"
  unattributed=$(usage_run "$case_root" attribution | jq -r '.unattributed_tokens')
  [ "$unattributed" = 0 ] \
    || fail "the re-dispatched occupancy's usage was orphaned by the old window: $unattributed"
  pass "a re-dispatched task id starts a fresh window instead of inheriting a closed one"
}

# The same slot, but the first task's records vanish without a manifest ever
# being published. Liveness is a fact about the current scan, so the vanished
# task stops claiming the slot instead of contesting every later task forever.
test_a_task_whose_live_records_vanish_stops_claiming_its_slot() {
  local case_root
  case_root=$(new_case vanished-task)
  local worktree="$case_root/worktrees/pool-slot-2"
  mkdir -p "$worktree"
  write_meta_at "$case_root/home/state/gone.meta" 202608010900.00 \
    "window=fm:gone" "worktree=$worktree" "project=demo" "harness=claude" "kind=ship"
  local dir="$case_root/claude/-pool-slot-2"
  mkdir -p "$dir"
  claude_line "$dir/gone.jsonl" session-gone "$worktree" 2026-08-01T10:00:00Z msg_g1 10 20 30 40
  usage_run "$case_root" ingest >/dev/null || fail "the first task's ingest failed"

  rm -f "$case_root/home/state/gone.meta" "$case_root/home/state/gone.usage-sessions"
  write_meta_at "$case_root/home/state/next.meta" 202608011100.00 \
    "window=fm:next" "worktree=$worktree" "project=demo" "harness=claude" "kind=ship"
  claude_line "$dir/next.jsonl" session-next "$worktree" 2026-08-01T11:30:00Z msg_n1 1 2 3 4

  local out
  out=$(usage_run "$case_root" ingest) || fail "the second task's ingest failed"
  [ "$(jq -r '.tasks.live_records_gone' <<<"$out")" = 1 ] \
    || fail "a task whose live records vanished must be retired: $(jq -c '.tasks' <<<"$out")"
  [ "$(jq -r '.sessions_bound' <<<"$out")" = 1 ] \
    || fail "the task holding the slot must still bind its own session: $out"

  local report
  report=$(usage_run "$case_root" report --by task)
  [ "$(jq -r '.rows[] | select(.key == "gone") | .total_tokens' <<<"$report")" = 100 ] \
    || fail "the vanished task lost the usage it had already earned: $report"
  [ "$(jq -r '.rows[] | select(.key == "next") | .total_tokens' <<<"$report")" = 10 ] \
    || fail "the task holding the slot did not get its own usage: $report"
  pass "a task whose live records vanish stops claiming its worktree slot"
}

test_unattributed_usage_is_preserved() {
  local case_root
  case_root=$(new_case unattributed)
  local worktree="$case_root/worktrees/slot-3"
  mkdir -p "$worktree" "$case_root/home/data/charlie"
  # An archived task that held this worktree for a bounded window.
  jq -n --arg worktree "$worktree" '{schema:"fm-outcome-manifest.v1",task_id:"charlie",
    home:"/home/fleet",title:null,project:"demo",kind:"ship",mode:"no-mistakes",yolo:"off",
    harness:"claude",model:"claude-opus-5",effort:"high",
    timestamps:{created:null,started:"2026-08-01T09:00:00Z",completed:"2026-08-01T10:30:00Z"},
    timestamp_sources:{created:null,started:"meta_mtime",completed:"explicit"},
    outcome:{state:"done",detail:null,source:"status_event",forced:false},
    pr:{url:null,provider:null,host:null,path:null,number:null,head:null,
        status:{state:"unknown",draft:null,review:"unknown",checks:"unknown",
                mergeable:"unknown",head:null,observed_at:null,source:"absent"}},
    report:{path:"/home/fleet/data/charlie/report.md",present:false},
    attribution:{backend:"tmux",endpoint:{target:"fm:charlie",task_id:null},
                 worktree:$worktree,task_tmp:null,traceparent:null,secondmate_home:null,
                 sessions:[]},
    work_items:{schema:"fm-work-items.v1",references:[]},
    gbrain:{status:"absent",receipt:null,observed_at:null,detail:null},
    recorded_at:"2026-08-01T10:30:00Z"}' > "$case_root/home/data/charlie/outcome.json"

  local dir="$case_root/claude/-slot-3"
  mkdir -p "$dir"
  # Inside the task's worktree and its lifetime: attributable.
  claude_line "$dir/inside.jsonl" session-inside "$worktree" 2026-08-01T10:00:00Z msg_in 1 1 1 1
  # The same worktree well after the task released it: the path alone is not a
  # claim, and a time window alone must never produce one.
  claude_line "$dir/after.jsonl" session-after "$worktree" 2026-08-01T11:30:00Z msg_after 2 2 2 2
  # Firstmate's own session, in no task's worktree at all.
  mkdir -p "$case_root/claude/-home-fleet"
  claude_line "$case_root/claude/-home-fleet/own.jsonl" session-own /home/fleet \
    2026-08-01T10:10:00Z msg_own 3 3 3 3

  usage_run "$case_root" ingest >/dev/null || fail "ingest failed"
  local report attribution
  report=$(usage_run "$case_root" report --by task)
  attribution=$(usage_run "$case_root" attribution)

  [ "$(jq -r '.rows[] | select(.key == "charlie") | .total_tokens' <<<"$report")" = 4 ] \
    || fail "usage inside the task's own window must be attributed: $report"
  [ "$(jq -r '.rows[] | select(.key == "(unattributed)") | .total_tokens' <<<"$report")" = 20 ] \
    || fail "usage outside every task must be preserved as unattributed: $report"
  [ "$(jq -r '.by_method[] | select(.method == "worktree_window") | .confidence' <<<"$attribution")" = medium ] \
    || fail "a post-hoc worktree match should report medium confidence: $attribution"
  [ "$(jq -r '.by_method[] | select(.method == "unknown") | .events' <<<"$attribution")" = 2 ] \
    || fail "unattributed events must stay visible with explicit unknown fields: $attribution"
  [ "$(jq -r '.unattributed_tokens' <<<"$attribution")" = 20 ] \
    || fail "unattributed tokens must be reported: $attribution"
  local percent
  percent=$(jq -r '.percent_events_attributed' <<<"$attribution")
  [ "$percent" != null ] || fail "the percentage matched must be reported"
  pass "unattributed usage is preserved and never guessed from a time window alone"
}

test_ambiguous_attribution_is_refused() {
  local case_root
  case_root=$(new_case ambiguous)
  local worktree="$case_root/worktrees/slot-4"
  mkdir -p "$worktree"
  # Two live tasks recorded against the same worktree: an overlapping claim is
  # refused rather than resolved by guessing.
  write_meta_at "$case_root/home/state/dup-one.meta" 202608010900.00 \
    "window=fm:dup-one" "worktree=$worktree" "project=demo" "harness=claude" "kind=ship"
  write_meta_at "$case_root/home/state/dup-two.meta" 202608010900.00 \
    "window=fm:dup-two" "worktree=$worktree" "project=demo" "harness=claude" "kind=ship"
  local dir="$case_root/claude/-slot-4"
  mkdir -p "$dir"
  claude_line "$dir/x.jsonl" session-x "$worktree" 2026-08-01T10:00:00Z msg_x 5 5 5 5

  usage_run "$case_root" ingest >/dev/null || fail "ingest failed"
  local attribution
  attribution=$(usage_run "$case_root" attribution)
  [ "$(jq -r '.attributed_events' <<<"$attribution")" = 0 ] \
    || fail "an ambiguous worktree claim must not attribute: $attribution"
  [ "$(jq -r '.by_method[] | select(.method == "ambiguous") | .events' <<<"$attribution")" = 1 ] \
    || fail "an ambiguous claim must be disclosed as such: $attribution"
  pass "overlapping worktree claims are disclosed as ambiguous instead of guessed"
}

# --- Rollups, burn rate, and cost -------------------------------------------

test_rollups_reconcile() {
  local case_root
  case_root=$(new_case rollups)
  local worktree="$case_root/worktrees/slot-5"
  mkdir -p "$worktree"
  write_meta_at "$case_root/home/state/echo.meta" 202608010900.00 \
    "window=fm:echo" "worktree=$worktree" "project=demo" "harness=claude" "kind=ship"
  local dir="$case_root/claude/-slot-5"
  mkdir -p "$dir"
  claude_line "$dir/a.jsonl" session-r1 "$worktree" 2026-08-01T10:00:00Z msg_r1 10 20 30 40
  claude_line "$dir/a.jsonl" session-r1 "$worktree" 2026-08-01T11:00:00Z msg_r2 1 2 3 4
  mkdir -p "$case_root/claude/-elsewhere"
  claude_line "$case_root/claude/-elsewhere/b.jsonl" session-r2 /elsewhere \
    2026-08-01T10:30:00Z msg_r3 7 7 7 7
  local rollout="$case_root/codex/2026/08/01/rollout-session-r3.jsonl"
  codex_rollout "$rollout" session-r3 "$worktree" gpt-5.6-sol
  codex_token_count "$rollout" 2026-08-01T10:45:00Z 100 20 30 5

  usage_run "$case_root" ingest >/dev/null || fail "ingest failed"
  local total by
  total=$(usage_run "$case_root" report --by harness | jq '[.rows[].total_tokens] | add')
  for by in task project model day; do
    local sum
    sum=$(usage_run "$case_root" report --by "$by" | jq '[.rows[].total_tokens] | add')
    [ "$sum" = "$total" ] || fail "the $by rollup ($sum) must reconcile with the total ($total)"
  done
  local task_total
  task_total=$(usage_run "$case_root" report --by task | jq -r '.rows[] | select(.key == "echo") | .total_tokens')
  local per_task
  per_task=$(usage_run "$case_root" sessions --task echo | jq '.sessions | length')
  [ "$per_task" = 2 ] || fail "the task's own sessions should be listed, got $per_task"
  # 100 + 10 from the two Claude responses, 120 from the Codex turn. Codex
  # reasoning tokens are part of its output count and its cached tokens are part
  # of its input count, so neither is added again.
  [ "$task_total" = 230 ] || fail "per-task rows must match their events, got $task_total"

  # A burn RATE is only a rate if events actually aggregate into their bucket.
  # The four events sit in two hours - 10:00, 10:30, and 10:45 in the first,
  # 11:00 in the second - so an hourly series has exactly two buckets, each
  # stamped on its hour boundary rather than on some event's own second. A
  # per-event series would still reconcile with the totals, which is why the
  # shape is asserted and not just the sum.
  local burn
  burn=$(FM_USAGE_NOW=2026-08-01T12:00:00Z usage_run "$case_root" burn --bucket hour --buckets 6)
  [ "$(jq -r '.schema' <<<"$burn")" = fm-usage-burn.v1 ] || fail "burn schema wrong"
  [ "$(jq -c '[.series[] | {bucket_start,events}]' <<<"$burn")" \
    = '[{"bucket_start":"2026-08-01T10:00:00Z","events":3},{"bucket_start":"2026-08-01T11:00:00Z","events":1}]' ] \
    || fail "hourly buckets must aggregate on hour boundaries, got $(jq -c '.series' <<<"$burn")"
  [ "$(jq '[.series[].total_tokens] | add' <<<"$burn")" = "$total" ] \
    || fail "the burn series must reconcile with stored totals"
  # The series is bounded by the window it was asked for, not by how many events
  # happen to fall inside it. A rolling window starts mid-bucket, so N buckets of
  # history can touch N+1 bucket boundaries - and never more.
  [ "$(jq '(.series | length) <= (.buckets + 1)' <<<"$burn")" = true ] \
    || fail "the series must stay bounded by the buckets requested"
  # The same events under a daily bucket collapse to one midnight-aligned day.
  local daily
  daily=$(FM_USAGE_NOW=2026-08-01T12:00:00Z usage_run "$case_root" burn --bucket day --buckets 3)
  [ "$(jq -c '[.series[] | {bucket_start,events}]' <<<"$daily")" \
    = '[{"bucket_start":"2026-08-01T00:00:00Z","events":4}]' ] \
    || fail "daily buckets must aggregate on day boundaries, got $(jq -c '.series' <<<"$daily")"
  [ "$(jq -r '.series[0].tokens_per_hour' <<<"$daily")" \
    = "$(jq -rn --argjson t "$total" '($t / 86400 * 3600) | round')" ] \
    || fail "the daily rate must spread the day's tokens over the day, got $(jq -c '.series' <<<"$daily")"
  local refused
  refused=$(usage_run "$case_root" burn --buckets 1000 2>&1); local code=$?
  expect_code 2 "$code" "an unbounded burn series must be refused"
  assert_contains "$refused" "--buckets must be between" "the refusal should name the bound"
  pass "rollups and the bounded burn series reconcile with the per-task rows"
}

test_cost_is_an_optional_versioned_estimate() {
  local case_root
  case_root=$(new_case cost)
  local dir="$case_root/claude/-costed"
  mkdir -p "$dir"
  claude_line "$dir/a.jsonl" session-cost /costed 2026-08-01T10:00:00Z msg_cost 1000000 1000000 0 0
  local rollout="$case_root/codex/2026/08/01/rollout-session-unpriced.jsonl"
  codex_rollout "$rollout" session-unpriced /costed gpt-5.6-sol
  codex_token_count "$rollout" 2026-08-01T10:05:00Z 500 500 0 0

  usage_run "$case_root" ingest >/dev/null || fail "ingest failed"
  local row
  row=$(usage_run "$case_root" report --by harness | jq -c '.rows[] | select(.key == "claude")')
  [ "$(jq -r '.cost' <<<"$row")" = null ] || fail "cost must be unknown without a rate file: $row"
  [ "$(jq -r '.total_tokens' <<<"$row")" = 2000000 ] \
    || fail "tokens must be reported even when cost is unknown: $row"

  jq -n '{schema:"fm-usage-rates.v1",rate_version:"2026-08-01",currency:"USD",
          models:{"claude-opus-5":{input:15,output:75,cache_read:1.5,cache_write:18.75}}}' \
    > "$case_root/home/config/usage-rates.json"
  local out
  out=$(usage_run "$case_root" ingest) || fail "priced ingest failed"
  [ "$(jq -r '.cost.rate_version' <<<"$out")" = 2026-08-01 ] || fail "the estimate must be versioned: $out"
  [ "$(jq -r '.cost.events_unpriced' <<<"$out")" = 1 ] \
    || fail "a model with no published rate must stay explicitly unpriced: $out"
  row=$(usage_run "$case_root" report --by harness | jq -c '.rows[] | select(.key == "claude")')
  [ "$(jq -r '.cost.estimated' <<<"$row")" = 90 ] || fail "the estimate is wrong: $row"
  [ "$(jq -r '.cost.currency' <<<"$row")" = USD ] || fail "the estimate must carry its currency: $row"
  local codex_row
  codex_row=$(usage_run "$case_root" report --by harness | jq -c '.rows[] | select(.key == "codex")')
  [ "$(jq -r '.cost' <<<"$codex_row")" = null ] \
    || fail "an unpriced model must keep tokens without an invented cost: $codex_row"
  [ "$(jq -r '.total_tokens' <<<"$codex_row")" = 1000 ] || fail "unpriced tokens must still count: $codex_row"
  pass "cost stays an optional versioned estimate and never stands in for tokens"
}

# --- Secret safety ----------------------------------------------------------

test_store_carries_no_transcript_content() {
  local case_root
  case_root=$(new_case redaction)
  local dir="$case_root/claude/-secret"
  mkdir -p "$dir"
  local file="$dir/session.jsonl"
  : > "$file"
  claude_noise "$file" session-secret /secret
  claude_line "$file" session-secret /secret 2026-08-01T10:00:00Z msg_secret 5 5 5 5
  local rollout="$case_root/codex/2026/08/01/rollout-session-secret.jsonl"
  codex_rollout "$rollout" session-secret2 /secret gpt-5.6-sol
  codex_token_count "$rollout" 2026-08-01T10:05:00Z 100 10 5 1

  usage_run "$case_root" ingest >/dev/null || fail "ingest failed"
  local sentinel
  for sentinel in SECRET_USER_PROMPT SECRET_ASSISTANT_PROSE SECRET_TOOL_ARGUMENT \
    TOKEN_ghp_SECRETCREDENTIAL SECRET_CODEX_PROMPT SECRET_CODEX_INSTRUCTIONS; do
    local hit
    hit=$(grep -rlF "$sentinel" "$case_root/home/data" 2>/dev/null || true)
    [ -z "$hit" ] || fail "the usage store must contain no transcript content, found $sentinel in $hit"
  done
  pass "the store contains no prompt or response bodies and no credentials"
}

test_claude_adapter
test_codex_adapter
test_reprocessing_is_idempotent
test_overlapping_collector_windows
test_malformed_and_rotated_sources
test_live_attribution_and_session_map
test_totals_survive_teardown
test_a_recycled_worktree_slot_belongs_to_the_task_holding_it
test_a_redispatched_task_id_starts_a_fresh_window
test_a_task_whose_live_records_vanish_stops_claiming_its_slot
test_unattributed_usage_is_preserved
test_ambiguous_attribution_is_refused
test_rollups_reconcile
test_cost_is_an_optional_versioned_estimate
test_store_carries_no_transcript_content
