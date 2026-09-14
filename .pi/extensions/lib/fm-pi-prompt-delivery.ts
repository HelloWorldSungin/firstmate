import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";

// Primary Pi prompt delivery owner (stated once here).
//
// Pi's AgentSession.prompt() decides between "queue into the running turn" and
// "start a new turn" before its preflight (auth check, pre-send compaction
// check, every extension before_agent_start handler), then enters
// _runAgentPrompt only after that preflight settles. Two prompts that both
// start while main is idle therefore both choose "start a new turn", and the
// one whose preflight settles second reaches Agent.prompt() while the first
// turn is running. Pi rejects it with "Agent is already processing a prompt",
// an extension send surfaces that rejection as the `Extension "<runtime>"
// error` banner, a captain prompt surfaces it as `Error:`, and the losing
// message is dropped. The rejected run also emits a spurious agent_settled
// that marks the still-running turn idle. Pi's extension API offers no
// awaitable send and no preflight hook, so no extension-side retry can observe
// or prevent that rejection; delaying sends only narrows the window.
//
// This module owns the one seam where the collision happens. It wraps
// AgentSession._runAgentPrompt so a prompt that reaches it while another turn
// is running joins that turn through Pi's own queues instead of being
// rejected: a captain or other non-operational user prompt is queued as a
// steer, exactly as Pi queues input typed while main is streaming, and a
// Firstmate operational prompt or custom message is queued as a follow-up,
// exactly as its sender asked for a streaming main. Pi's running turn drains
// both queues before it settles, so the joined message reaches the model in
// that turn and raises its user message_start there. A join that lands after
// the running turn has already made its final queue check is started as its
// own turn once that turn settles, so nothing is left queued behind an idle
// main. Every Firstmate primary prompt source (watcher wakes, turn-end guard
// nudges, supervision-branch processing requests) and every captain prompt
// passes this seam, so no per-extension retry loop exists to race it.
//
// The wrap is process-global and idempotent: the first extension factory to
// load installs it, and later factories, reloads, and session replacements
// reuse a stable trampoline with the latest registered implementation. Joined
// user text enters the session queue bookkeeping for display and editor restore;
// stranded restart failures are reported through the extension runner.
// A Pi build that lacks the seam is reported, never
// silently patched around; the watcher extension surfaces that report.

type QueuedMessage = { role?: unknown; content?: unknown };

type PendingQueue = { hasItems?: () => boolean; drain?: () => QueuedMessage[] };

type JoinableAgent = {
  state?: { isStreaming?: unknown };
  steer?: (message: QueuedMessage) => void;
  followUp?: (message: QueuedMessage) => void;
  hasQueuedMessages?: () => boolean;
  steeringQueue?: PendingQueue;
  followUpQueue?: PendingQueue;
};

type JoinableSession = {
  agent?: JoinableAgent;
  _isAgentRunActive?: unknown;
  isCompacting?: unknown;
  _steeringMessages?: string[];
  _followUpMessages?: string[];
  _emitQueueUpdate?: () => void;
  _extensionRunner?: {
    emitError?: (error: { extensionPath: string; event: string; error: string }) => void;
  };
};

type RunAgentPrompt = (this: JoinableSession, messages: QueuedMessage | QueuedMessage[]) => Promise<void>;

type JoinableSessionClass = { prototype: { _runAgentPrompt?: RunAgentPrompt } };

export type PromptDeliveryInstall = { ok: true } | { ok: false; detail: string };

export type OperationalClassifier = (text: string) => boolean;

type PromptDeliveryEntry = { original: RunAgentPrompt; implementation: RunAgentPrompt };

type PromptDeliveryRegistry = typeof globalThis & {
  [key: symbol]: WeakMap<object, PromptDeliveryEntry> | undefined;
};

// Keep the introduction-version symbol stable so a reload or a compatible
// upgrade of this module cannot wrap the same live prototype twice.
const PROMPT_DELIVERY_WRAPS = Symbol.for("firstmate:pi-prompt-delivery:pi-0.85.1");

function wrappedPrototypes(): WeakMap<object, PromptDeliveryEntry> {
  const registry = globalThis as PromptDeliveryRegistry;
  return (registry[PROMPT_DELIVERY_WRAPS] ??= new WeakMap<object, PromptDeliveryEntry>());
}

function messageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: "text"; text: string } =>
      typeof part === "object" && part !== null &&
      (part as { type?: unknown }).type === "text" &&
      typeof (part as { text?: unknown }).text === "string")
    .map((part) => part.text)
    .join("\n");
}

function isOperationalText(text: string): boolean {
  return classifyFirstmateCurrentOperationalText(text) !== undefined;
}

function joinable(session: JoinableSession): boolean {
  const agent = session.agent;
  return typeof session._isAgentRunActive === "boolean" &&
    typeof agent?.steer === "function" &&
    typeof agent.followUp === "function";
}

function turnRunning(session: JoinableSession): boolean {
  return session._isAgentRunActive === true || session.agent?.state?.isStreaming === true;
}

function drainQueue(queue: PendingQueue | undefined): QueuedMessage[] {
  const drained: QueuedMessage[] = [];
  if (typeof queue?.drain !== "function" || typeof queue.hasItems !== "function") return drained;
  while (queue.hasItems()) drained.push(...queue.drain());
  return drained;
}

// Messages a session queued after its last turn's final queue check, found at
// that turn's settlement with no other turn running or preflighting into one.
function strandedMessages(session: JoinableSession): QueuedMessage[] {
  const agent = session.agent;
  if (turnRunning(session) || session.isCompacting === true) return [];
  if (typeof agent?.hasQueuedMessages !== "function" || !agent.hasQueuedMessages()) return [];
  return [...drainQueue(agent.steeringQueue), ...drainQueue(agent.followUpQueue)];
}

// Install the join on one AgentSession-shaped class. Exported so the portable
// suite can drive the same wrap against a session double; production callers
// use installPiPromptDelivery().
export function installPromptJoin(
  sessionClass: JoinableSessionClass | undefined,
  isOperational: OperationalClassifier = isOperationalText,
): PromptDeliveryInstall {
  const prototype = sessionClass?.prototype;
  if (!prototype) return { ok: false, detail: "AgentSession is not exported" };
  const registry = wrappedPrototypes();
  const installed = registry.get(prototype);
  const original = installed?.original ?? prototype._runAgentPrompt;
  if (typeof original !== "function") return { ok: false, detail: "AgentSession._runAgentPrompt is missing" };

  const joinRunningTurn = function (this: JoinableSession, messages: QueuedMessage | QueuedMessage[]): boolean {
    if (!joinable(this) || !turnRunning(this)) return false;
    const queued = Array.isArray(messages) ? messages : [messages];
    const lead = queued[0];
    const steer = lead?.role === "user" && !isOperational(messageText(lead.content));
    if (lead?.role === "user") {
      const pending = steer ? this._steeringMessages : this._followUpMessages;
      if (!Array.isArray(pending)) return false;
      pending.push(messageText(lead.content));
      if (typeof this._emitQueueUpdate === "function") this._emitQueueUpdate();
    }
    const agent = this.agent as Required<Pick<JoinableAgent, "steer" | "followUp">>;
    for (const message of queued) {
      if (steer) agent.steer(message);
      else agent.followUp(message);
    }
    return true;
  };

  const wrapped: RunAgentPrompt = async function (this: JoinableSession, messages) {
    if (joinRunningTurn.call(this, messages)) return;
    try {
      await original.call(this, messages);
    } finally {
      const stranded = strandedMessages(this);
      if (stranded.length > 0) {
        void entry.implementation.call(this, stranded).catch((error: unknown) => {
          try {
            if (typeof this._extensionRunner?.emitError === "function") {
              this._extensionRunner.emitError({
                extensionPath: ".pi/extensions/lib/fm-pi-prompt-delivery.ts",
                event: "agent_settled",
                error: error instanceof Error ? error.message : String(error),
              });
            }
          } catch {}
        });
      }
    }
  };
  const entry = installed ?? { original, implementation: wrapped };
  entry.implementation = wrapped;
  if (!installed) {
    registry.set(prototype, entry);
    prototype._runAgentPrompt = function (messages) {
      return entry.implementation.call(this, messages);
    };
  }
  return { ok: true };
}

export function installPiPromptDelivery(): PromptDeliveryInstall {
  // _runAgentPrompt is private in Pi's typings, so the class is read through the
  // structural seam this module checks at runtime.
  const sessionClass = (PiCodingAgent as unknown as { AgentSession?: JoinableSessionClass }).AgentSession;
  const result = installPromptJoin(sessionClass);
  if (result.ok) return result;
  const version = (PiCodingAgent as { VERSION?: unknown }).VERSION;
  return {
    ok: false,
    detail: `Pi ${typeof version === "string" ? version : "(unknown version)"}: ${result.detail}`,
  };
}
