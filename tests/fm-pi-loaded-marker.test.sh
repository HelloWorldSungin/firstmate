#!/usr/bin/env bash
# Tests for the Pi primary extensions' loaded-generation marker writer rule
# (.pi/extensions/lib/fm-pi-loaded-marker.ts) as the watch and turn-end guard
# extensions apply it, and for the proof bin/fm-wake-lib.sh draws from those
# markers. A `pi --list-models` probe the primary runs from its own bash tool
# loads the same extension factories from disk as a descendant of the lock
# holder; it must never replace the holder's evidence, so stale primary code can
# never read as current and current code can never read as unloaded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-loaded-marker)
export NODE_NO_WARNINGS=1

install_marker_fixture() { # <repo>
  local repo=$1
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$ROOT/.pi/extensions/lib/fm-async-exec.ts" \
    "$ROOT/.pi/extensions/lib/fm-native-contract.ts" \
    "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$ROOT/.pi/extensions/lib/fm-pi-loaded-marker.ts" "$ROOT/.pi/extensions/lib/fm-pi-prompt-delivery.ts" \
    "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-watch-arm.sh"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
    > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf '%s\n' 'export function getMarkdownTheme() { return {}; }' 'export class UserMessageComponent {}' \
    > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js"
  printf '%s\n' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' \
    > "$repo/node_modules/@earendil-works/pi-tui/package.json"
  printf '%s\n' 'export class Box { addChild() {} clear() {} setBgFn() {} }' 'export class Container {}' 'export class Text {}' \
    > "$repo/node_modules/@earendil-works/pi-tui/index.js"
  printf '%s\n' '{"name":"typebox","type":"module","exports":"./index.js"}' > "$repo/node_modules/typebox/package.json"
  printf '%s\n' 'export const Type = { Object(properties) { return { type: "object", properties }; } };' \
    > "$repo/node_modules/typebox/index.js"
}

test_writer_rule_through_both_extensions() {
  local repo home script out status
  repo="$TMP_ROOT/writer-root"
  home="$TMP_ROOT/writer-home"
  script="$TMP_ROOT/writer-rule.mjs"
  mkdir -p "$home/state" "$home/config"
  install_marker_fixture "$repo"
  # Written outside any command substitution: stock macOS Bash 3.2 cannot parse
  # a quoted heredoc containing apostrophes inside $(...).
  cat > "$script" <<'EOF'
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const state = `${process.env.FM_HOME}/state`;
const lock = `${state}/.lock`;
const fail = (message) => {
  throw new Error(message);
};
const extensions = [
  { file: "fm-primary-pi-watch.ts", marker: `${state}/.pi-watch-extension-loaded` },
  { file: "fm-primary-turnend-guard.ts", marker: `${state}/.pi-turnend-extension-loaded` },
];
let load = 0;
async function startSession(extension) {
  const handlers = new Map();
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage() {},
    sendMessage() {},
    events: { on() {}, emit() {} },
  };
  const path = `${process.env.REPO}/.pi/extensions/${extension.file}`;
  const mod = await import(`${pathToFileURL(path).href}?load=${++load}`);
  mod.default(pi);
  return {
    version: `sha256:${createHash("sha256").update(readFileSync(path)).digest("hex")}`,
    start: () => handlers.get("session_start")?.({ type: "session_start", reason: "reload" }, {}),
    stop: () => handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {}),
  };
}
const read = (marker) => existsSync(marker) ? readFileSync(marker, "utf8") : "(absent)";
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });

try {
  for (const extension of extensions) {
    const { marker } = extension;
    rmSync(marker, { force: true });

    // Factory load alone (what a model-list probe does) records nothing.
    writeFileSync(lock, `${process.pid}\n`);
    const probe = await startSession(extension);
    if (existsSync(marker)) fail(`${extension.file} recorded a marker at factory load: ${read(marker)}`);

    // A live descendant of the lock holder never replaces the holder's evidence.
    writeFileSync(lock, `${process.ppid}\n`);
    writeFileSync(marker, `sha256:holder-evidence\n${process.ppid}\n`);
    await probe.start();
    if (read(marker) !== `sha256:holder-evidence\n${process.ppid}\n`) {
      fail(`${extension.file} descendant overwrote holder evidence: ${read(marker)}`);
    }
    await probe.stop();

    // Nor does a live unrelated holder's session.
    writeFileSync(lock, `${other.pid}\n`);
    const unrelated = await startSession(extension);
    await unrelated.start();
    if (read(marker) !== `sha256:holder-evidence\n${process.ppid}\n`) {
      fail(`${extension.file} overwrote another live session's evidence: ${read(marker)}`);
    }
    await unrelated.stop();

    // The lock holder's own session records exactly its build and pid.
    writeFileSync(lock, `${process.pid}\n`);
    const holder = await startSession(extension);
    await holder.start();
    if (read(marker) !== `${holder.version}\n${process.pid}\n`) fail(`${extension.file} holder did not record its evidence: ${read(marker)}`);
    await holder.stop();

    // No live holder yet (absent or dead lock): the starting session records.
    for (const [label, prepare] of [["absent", () => rmSync(lock, { force: true })], ["dead", () => writeFileSync(lock, "999999\n")]]) {
      rmSync(marker, { force: true });
      prepare();
      const fresh = await startSession(extension);
      await fresh.start();
      if (read(marker) !== `${fresh.version}\n${process.pid}\n`) fail(`${extension.file} ${label} lock did not record: ${read(marker)}`);
      await fresh.stop();
    }
  }
} finally {
  other.kill("SIGTERM");
}
process.exit(0);
EOF
  out=$(cd "$repo" && FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" REPO="$repo" \
    node --experimental-strip-types "$script" 2>&1)
  status=$?
  expect_code 0 "$status" "loaded-marker writer rule: $out"
  [ -z "$out" ] || fail "loaded-marker writer rule printed output: $out"
  pass "watch and turn-end guard extensions record loaded evidence only from a started session run by the lock holder (or with no live holder), never at factory load, from a descendant, or over another live session"
}

test_real_model_list_probe_cannot_rewrite_evidence() {
  local project home agent watch turnend watch_version turnend_version holder out
  if ! command -v pi >/dev/null 2>&1; then
    echo "skip: pi not found for the real model-list probe"
    return 0
  fi
  project="$TMP_ROOT/probe-project"
  home="$TMP_ROOT/probe-home"
  agent="$TMP_ROOT/probe-agent"
  mkdir -p "$project" "$home/state" "$home/config" "$agent"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch_version=$(fm_pi_extension_version "$watch")
  turnend_version=$(fm_pi_extension_version "$turnend")
  # This shell stands in for the primary: it holds the lock, and the probe is
  # its descendant, exactly as when the primary's bash tool runs the probe.
  holder=$$
  printf '%s\n' "$holder" > "$home/state/.lock"

  probe() {
    (cd "$project" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PI_CODING_AGENT_DIR="$agent" PI_OFFLINE=1 \
      pi --approve --no-extensions -e "$turnend" -e "$watch" --list-models >/dev/null 2>&1)
  }

  # Stale primary code: the holder loaded an older build. A probe loading the
  # current files must not make that holder read as running current code.
  printf 'sha256:stale-watch\n%s\n' "$holder" > "$home/state/.pi-watch-extension-loaded"
  printf 'sha256:stale-turnend\n%s\n' "$holder" > "$home/state/.pi-turnend-extension-loaded"
  probe || fail "pi --list-models probe failed to run"
  out=$(cat "$home/state/.pi-watch-extension-loaded" "$home/state/.pi-turnend-extension-loaded")
  [ "$out" = "$(printf 'sha256:stale-watch\n%s\nsha256:stale-turnend\n%s' "$holder" "$holder")" ] \
    || fail "model-list probe rewrote stale holder evidence: $out"
  if fm_pi_extension_loaded "$home/state/.pi-watch-extension-loaded" "$watch_version" "$home/state/.lock"; then
    fail "stale primary watch code reads as current after a model-list probe"
  fi

  # Current primary code: the probe must not replace the holder's pid with its
  # own and make a loaded primary read as unloaded.
  printf '%s\n%s\n' "$watch_version" "$holder" > "$home/state/.pi-watch-extension-loaded"
  printf '%s\n%s\n' "$turnend_version" "$holder" > "$home/state/.pi-turnend-extension-loaded"
  probe || fail "pi --list-models probe failed to run"
  fm_pi_extension_loaded "$home/state/.pi-watch-extension-loaded" "$watch_version" "$home/state/.lock" \
    || fail "model-list probe made current watch evidence unprovable: $(cat "$home/state/.pi-watch-extension-loaded")"
  fm_pi_extension_loaded "$home/state/.pi-turnend-extension-loaded" "$turnend_version" "$home/state/.lock" \
    || fail "model-list probe made current turn-end evidence unprovable: $(cat "$home/state/.pi-turnend-extension-loaded")"
  pass "a real pi $(pi --version 2>/dev/null) --list-models probe run under the lock holder leaves both loaded markers exactly as the holder recorded them"
}

test_writer_rule_through_both_extensions
test_real_model_list_probe_cannot_rewrite_evidence

printf '\nall fm-pi-loaded-marker tests passed\n'
