#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-array-dispatch skill.
#
# This drives the public Pi skill-loading interface against a fake quota-axi
# executable rather than parsing instruction source bytes or recreating the
# selector in test code. The fake serves default TOON from the schema-5 JSON
# fixture; --json remains available so a TOON-first skill cannot silently
# fall back without the call log catching it.
set -u

if [ "${FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E=1 to run the credentialed Pi dispatch-selection regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -f "$OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/quota.json"
AUTH_FIXTURE="$LAB/quota-auth.json"
CALLS="$LAB/quota-axi.calls"
SIDECAR_CALLS="$LAB/quota-sidecar.calls"
SIDECAR_FIXTURE="$LAB/quota-sidecar.json"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$PROJECT/bin" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"

# A case that publishes no sidecar fixture gets the reader's unmounted-share
# document, so the sidecar contributes no evidence unless the case says so.
cat > "$PROJECT/bin/fm-quota-sidecar.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${QUOTA_SIDECAR_CALLS:?}"
if [ -s "${QUOTA_SIDECAR_FIXTURE:-/nonexistent}" ]; then
  cat "$QUOTA_SIDECAR_FIXTURE"
  exit 0
fi
printf '%s\n' '{"schema":"fm-quota-sidecar-reader.v1","freshness_seconds":7200,"evidence_status":"UNKNOWN","providers":[],"reason":"no_provider_files"}'
SH
chmod +x "$PROJECT/bin/fm-quota-sidecar.sh"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
# Fake quota-axi: default TOON from the schema-5 JSON fixture; --json dumps it.
set -u
record() {
  printf '%s\n' "$1" >> "${QUOTA_AXI_CALLS:?}"
}
emit_toon() {
  python3 - "${QUOTA_AXI_FIXTURE:?}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
generated = data.get("generatedAt", "unknown")
quota = []
exhaustion = []
attention = []


def join_ids(ids):
    if not ids:
        return "unknown"
    return " + ".join(str(item) for item in ids)


for provider in data.get("providers") or []:
    name = provider.get("provider", "unknown")
    windows = {window.get("id"): window for window in (provider.get("windows") or [])}
    semantics = provider.get("quotaSemantics") or {}
    for scope in semantics.get("effectiveAvailability") or []:
        remaining = scope.get("effectivePercentRemaining")
        selection = scope.get("selection") or {}
        runway = scope.get("runway") or {}
        scope_name = scope.get("scope", "unknown")
        if remaining is None:
            attention.append(
                f"  {name},{scope_name},headroom_unknown,{join_ids(runway.get('unmeasurableWindowIds') or scope.get('boundedBy'))},none"
            )
            continue
        if selection.get("status") == "known" and "spendPriority" in selection:
            spend = selection["spendPriority"]
        else:
            spend = "unknown"
        runway_status = runway.get("status") or "unknown"
        confidence = runway.get("projectionConfidence") or "unknown"
        limited = join_ids(scope.get("limitingWindowIds"))
        binding = None
        for window_id in scope.get("limitingWindowIds") or []:
            binding = (windows.get(window_id) or {}).get("resetsAt")
            if binding:
                break
        resets_at = binding or "unknown"
        quota.append(
            f"  {name},{scope_name},{remaining},{spend},{runway_status},{confidence},{limited},{resets_at}"
        )
        if runway_status in ("projected_exhaustion", "exhausted_now"):
            seconds = runway.get("usableRunwaySeconds", "unknown")
            exhausted_at = runway.get("projectedExhaustedAt", "unknown")
            limiting = runway.get("limitingWindowId", "unknown")
            exhaustion.append(
                f"  {name},{scope_name},{seconds},{exhausted_at},{limiting}"
            )
        blocked = []
        if runway.get("unmeasurableWindowIds"):
            blocked.append(f"{join_ids(runway['unmeasurableWindowIds'])} blocks runway")
        if selection.get("unmeasurableWindowIds"):
            blocked.append(
                f"{join_ids(selection['unmeasurableWindowIds'])} blocks spendPriority"
            )
        if blocked:
            attention.append(
                f"  {name},{scope_name},unmeasurable,{' · '.join(blocked)},none"
            )

print('bin: fake-quota-axi')
print('description: Report local agent-provider quota windows for routing-aware agents')
print(f'generatedAt: "{generated}"')
print(
    f"quota[{len(quota)}]{{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}}:"
)
print("\n".join(quota) if quota else "")
print(
    f"exhaustion[{len(exhaustion)}]{{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}}:"
    if exhaustion
    else "exhaustion[0]:"
)
if exhaustion:
    print("\n".join(exhaustion))
print(
    f"attention[{len(attention)}]{{provider,scope,kind,detail,remedy}}:"
    if attention
    else "attention[0]:"
)
if attention:
    print("\n".join(attention))
print("help[1]:")
print("  Run `quota-axi --full` for windows, pace, reserve, and account evidence")
PY
}

case "$*" in
  ""|quota)
    record TOON
    emit_toon
    ;;
  --json)
    record JSON
    cat "${QUOTA_AXI_FIXTURE:?}"
    ;;
  *)
    printf 'unexpected quota-axi invocation: %s\n' "$*" >&2
    exit 64
    ;;
esac
SH
chmod +x "$FAKEBIN/quota-axi"

# The lab is the only skill revision under test, but the harness cannot hide the
# rest of the host: a developer machine or CI runner commonly holds another
# checkout of this repository, and the agent locates a named skill by reading the
# filesystem. Without this rule it sometimes reads `SKILL.md` from that other
# checkout and is then judged against instructions this branch never changed.
# The rule names no command, source, or evidence read, so the loaded skill's own
# text remains the only thing that decides what the intake runs.
SKILL_SOURCE_RULE='Load every named skill only from the .agents/skills directory under the current working directory. Never read an instruction, skill, or agent-context file from any other path on this host, even when a file of the same name exists elsewhere.'

write_fixture() {
  cat > "$FIXTURE"
}

write_auth_fixture() {
  cat > "$AUTH_FIXTURE"
}

write_sidecar_fixture() {
  cat > "$SIDECAR_FIXTURE"
}

run_case() {
  local label=$1 expected=$2 expected_calls=$3 prompt=$4 out calls required sidecar_calls
  shift 4
  : > "$CALLS"
  : > "$SIDECAR_CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
        QUOTA_AXI_AUTH_FIXTURE="$AUTH_FIXTURE" QUOTA_SIDECAR_CALLS="$SIDECAR_CALLS" \
        QUOTA_SIDECAR_FIXTURE="$SIDECAR_FIXTURE" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --append-system-prompt "$SKILL_SOURCE_RULE" \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "$calls" = "$expected_calls" ] || fail "$label: unexpected quota-axi call sequence: $calls"
  # No case prompt names the sidecar reader, so this asserts what the skill
  # itself drives: loading it must produce exactly one sidecar read per intake,
  # including in the case where quota-axi models no such provider family.
  sidecar_calls=$(wc -l < "$SIDECAR_CALLS" | tr -d ' ')
  [ "$sidecar_calls" = 1 ] \
    || fail "$label: skill did not use exactly one quota sidecar snapshot: $sidecar_calls"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || fail "$label: expected accounting line $required, got: $out"
  done
  printf '%s\n' "$out"
  printf 'ok - %s\n' "$label"
}

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 80,
          "resetsAt": "2030-01-07T07:12:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -10, "burnMultiple": 2 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 80,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -1.1111 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 241920,
              "projectedExhaustedAt": "2030-01-03T19:12:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -10, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 20,
          "resetsAt": "2030-01-03T19:12:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -20, "burnMultiple": 1.3333 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.8333 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 90720,
              "projectedExhaustedAt": "2030-01-02T01:12:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -20, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "higher spendPriority beats more headroom after the three gates" \
  "SELECTED=codex" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi with no flags (default TOON) exactly once. Do not pass --json. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Both candidates have known runway that supports that horizon. Return exact lines FACT=claude|headroom=80|spendPriority=-1.1111|runway_seconds=241920 and FACT=codex|headroom=20|spendPriority=-0.8333|runway_seconds=90720 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=80|spendPriority=-1.1111|runway_seconds=241920" \
  "FACT=codex|headroom=20|spendPriority=-0.8333|runway_seconds=90720"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 55,
          "resetsAt": "2030-01-08T00:00:00Z",
          "pace": { "status": "unknown", "reason": "missing_cycle" }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 55,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "unknown", "unmeasurableWindowIds": ["weekly"] },
            "runway": { "status": "unknown", "unmeasurableWindowIds": ["weekly"] },
            "pace": { "status": "unknown", "unknownWindowIds": ["weekly"] }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 45,
          "resetsAt": "2030-01-04T20:24:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -10, "burnMultiple": 1.2222 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 45,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.404 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 222676,
              "projectedExhaustedAt": "2030-01-03T13:51:16Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -10, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "unmeasurable runway stays eligible and is accounted for explicitly" \
  "DECISION=CODEX" \
  "TOON
JSON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and consult quota-axi's default TOON first. Because Claude spendPriority is the literal unknown, use the permitted quota-axi --json fallback once before deciding. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has higher known headroom but explicitly unmeasurable runway and unknown spendPriority, while Codex has lower known headroom, known spendPriority, and established runway that supports completion. Claude remains eligible and its uncertainty must be disclosed. Never read unknown spendPriority as 0. Return exact lines FACT=claude|eligible=yes|headroom=55|runway=unknown|spendPriority=unknown|unmeasurable=weekly and FACT=codex|eligible=yes|headroom=45|spendPriority=-0.404|runway_seconds=222676|supports_horizon=yes, then an exact final line DECISION=CODEX. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|eligible=yes|headroom=55|runway=unknown|spendPriority=unknown|unmeasurable=weekly" \
  "FACT=codex|eligible=yes|headroom=45|spendPriority=-0.404|runway_seconds=222676|supports_horizon=yes"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 5,
          "resetsAt": "2030-01-04T12:00:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -45, "burnMultiple": 1.9 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 5,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -1.8 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 15916,
              "projectedExhaustedAt": "2030-01-01T04:25:16Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -45, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 80,
          "resetsAt": "2030-01-06T22:48:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -5, "burnMultiple": 1.3333 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 80,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.3921 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 362880,
              "projectedExhaustedAt": "2030-01-05T04:48:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -5, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "required strongest reasoning class is not downgraded for quota" \
  "SELECTED=claude" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi with no flags (default TOON) exactly once. Do not pass --json. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile that meets the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class and cannot meet the requirement. Return exact lines FACT=claude|reasoning=required|headroom=5|spendPriority=-1.8|runway_seconds=15916 and FACT=codex|reasoning=weaker|headroom=80|spendPriority=-0.3921|runway_seconds=362880, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|reasoning=required|headroom=5|spendPriority=-1.8|runway_seconds=15916" \
  "FACT=codex|reasoning=weaker|headroom=80|spendPriority=-0.3921|runway_seconds=362880"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "five_hour",
          "label": "5-hour",
          "kind": "five_hour",
          "percentRemaining": 20,
          "resetsAt": "2030-01-01T02:00:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -20, "burnMultiple": 1.3333 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "boundedBy": ["five_hour"],
            "limitingWindowIds": ["five_hour"],
            "selection": { "status": "known", "spendPriority": -0.8333 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 2700,
              "projectedExhaustedAt": "2030-01-01T00:45:00Z",
              "limitingWindowId": "five_hour",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["five_hour"], "worstReservePercentPoints": -20, "worstReserveWindowId": "five_hour" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 5,
          "resetsAt": "2030-01-04T12:00:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -45, "burnMultiple": 1.9 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 5,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -1.8 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 15916,
              "projectedExhaustedAt": "2030-01-01T04:25:16Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -45, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "runway versus completion horizon remains a hard gate over spendPriority" \
  "SELECTED=codex" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi with no flags (default TOON) exactly once. Do not pass --json. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has known spendPriority of -0.8333 and runway of 2700 seconds. Codex has known spendPriority of -1.8 and runway of 15916 seconds. Return exact lines FACT=claude|spendPriority=-0.8333|runway_seconds=2700|supports_horizon=no and FACT=codex|spendPriority=-1.8|runway_seconds=15916|supports_horizon=yes to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|spendPriority=-0.8333|runway_seconds=2700|supports_horizon=no" \
  "FACT=codex|spendPriority=-1.8|runway_seconds=15916|supports_horizon=yes"

# An auth-gated catalog row can resolve a candidate's surface even when
# quota-axi does not model that provider family; this pins the distinction
# between positive surface evidence and unknown quota.
write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        { "id": "weekly", "label": "week", "kind": "weekly", "percentRemaining": 60, "resetsAt": "2030-01-07T07:12:00Z" }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 60,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.9 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 14400,
              "projectedExhaustedAt": "2030-01-01T04:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            }
          }
        ]
      }
    }
  ]
}
JSON
write_auth_fixture <<'JSON'
{"schemaVersion":1,"auth":[{"provider":"claude","sources":[{"source":"oauth-file","status":"available"}]}]}
JSON
run_case \
  "a provider family quota-axi does not model keeps a catalog-resolved surface" \
  "ELIGIBLE=BOTH" \
  "TOON
auth --json" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and consult quota-axi's default TOON exactly once; you may also run quota-axi auth --json. Do not pass --json to the quota read. Candidate A is harness=claude model=opus. Candidate B is harness=pi model=minimax/MiniMax-M3. Take this raw observation as given and draw your own conclusions from it: running the authoritative Pi catalog command printed the row 'minimax  MiniMax-M3  1M  128K  yes  yes'. That is the entire catalog evidence available; no further catalog command may be run to gather more of it. Both candidates have comparable required task fit and the same reasoning class for this work. For each candidate decide whether its authentication surface is resolved or unresolved, whether its applicable quota is known or unmodeled, and whether it is eligible. Return exact lines FACT=claude|eligible=<yes|no>|surface=<resolved|unresolved>|quota=<known|unmodeled> and FACT=minimax|eligible=<yes|no>|surface=<resolved|unresolved>|quota=<known|unmodeled>, then an exact final line ELIGIBLE=<BOTH|CLAUDE_ONLY>. Beyond the evidence reads your loaded skill directs, do not use other vendor or model commands, and do not modify files." \
  "FACT=claude|eligible=yes|surface=resolved|quota=known" \
  "FACT=minimax|eligible=yes|surface=resolved|quota=unmodeled"

# Where both sources cover a provider - Cursor today - the host-published sidecar
# may lag, so quota-axi owns the selection number and the sidecar stays
# corroborating diagnostics. This case is last because it is the only one that
# publishes a sidecar fixture. The prompt states that the sources disagree but
# never says which one wins, so the skill's precedence rule is what has to
# produce the authoritative number: an agent that took the sidecar's optimistic
# 95 would report headroom=95 and would have no reason to pass Cursor over.
write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "cursor",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        { "id": "included_usage", "label": "included", "kind": "monthly", "percentRemaining": 8, "resetsAt": "2030-01-02T00:00:00Z" }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 8,
            "boundedBy": ["included_usage"],
            "limitingWindowIds": ["included_usage"],
            "selection": { "status": "known", "spendPriority": -3.2 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 600,
              "projectedExhaustedAt": "2030-01-01T00:10:00Z",
              "limitingWindowId": "included_usage",
              "projectionConfidence": "established"
            }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        { "id": "weekly", "label": "week", "kind": "weekly", "percentRemaining": 60, "resetsAt": "2030-01-07T07:12:00Z" }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 60,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.4 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 14400,
              "projectedExhaustedAt": "2030-01-01T04:00:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            }
          }
        ]
      }
    }
  ]
}
JSON
write_sidecar_fixture <<'JSON'
{"schema":"fm-quota-sidecar-reader.v1","freshness_seconds":7200,"clock_skew_tolerance_seconds":300,"evidence_status":"CURRENT","providers":[{"provider":"cursor","evidence_status":"CURRENT","reason":"fresh","source_status":"ok","captured_at":"2030-01-01T00:00:00Z","captured_age_seconds":45,"last_attempt_at":"2030-01-01T00:00:00Z","last_attempt_age_seconds":45,"windows":[{"id":"included_usage","percent_remaining":95,"resets_at":"2030-01-02T00:00:00Z"}]}]}
JSON
run_case \
  "quota-axi stays authoritative where the sidecar overlaps it" \
  "SELECTED=codex" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and take every evidence read it directs exactly once, using quota-axi's default TOON rather than --json. Candidate A is harness=cursor model=composer-1. Candidate B is harness=codex model=gpt-5.6. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. Both candidates have comparable required task fit and the same reasoning class for this work. The likely task-completion horizon is two hours with established confidence. Your evidence reads disagree about how much of Cursor's included usage remains; resolve that disagreement by your own rules and account for it explicitly instead of averaging, merging, or caching either number. Return exact lines FACT=cursor|headroom=<n>|selection_source=<quota-axi|sidecar>|sidecar=<diagnostic|authoritative> and FACT=codex|headroom=60|runway_seconds=14400, then an exact final line SELECTED=<cursor|codex>. Beyond the evidence reads your loaded skill directs, do not use other vendor or model commands, and do not modify files." \
  "FACT=cursor|headroom=8|selection_source=quota-axi|sidecar=diagnostic" \
  "FACT=codex|headroom=60|runway_seconds=14400"

echo "# all quota-array-dispatch live behavior tests passed"
