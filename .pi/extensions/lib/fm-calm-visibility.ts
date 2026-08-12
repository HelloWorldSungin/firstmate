import {
  getMarkdownTheme,
  type ExtensionAPI,
  type UserMessageComponent as PiUserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
export const CALM_TRANSCRIPT_CLASSES = [
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-thinking",
  "assistant-tool-call",
  "tool-result",
  "tool-image",
  "user-bash",
  "skill-invocation",
  "custom-message",
  "custom-entry",
  "compaction-summary",
  "branch-summary",
  "working-status",
  "command-status",
  "system-notice",
  "cache-notice",
  "project-trust-warning",
  "synthetic-user",
  "synthetic-assistant",
  "unknown",
] as const;

export type CalmTranscriptClass = (typeof CALM_TRANSCRIPT_CLASSES)[number];

const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
  "working-status",
]);

// Legacy session entries from Calm versions before 2026-07-23 retain this
// presentation type. New operational input stays user-role and is never rerouted.
export const FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = "firstmate-synthetic-input-presentation";
export const FIRSTMATE_CALM_PRESENTATION_EVENT = "firstmate:calm-presentation";

export type CalmPresentationState = {
  active: boolean;
  stockExportRendering: boolean;
};

export const FIRSTMATE_SYNTHETIC_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-firstmate",
  "launch-brief",
  "legacy-operational",
] as const;

export type FirstmateSyntheticKind = (typeof FIRSTMATE_SYNTHETIC_KINDS)[number];
type FirstmateSyntheticPresentation = {
  content: string;
  kind: FirstmateSyntheticKind;
};

let calm = false;
let stockExportRendering = false;

export function calmTranscriptClassIsVisible(itemClass: CalmTranscriptClass): boolean {
  return CALM_VISIBLE_CLASSES.has(itemClass);
}

export function setCalmPresentation(active: boolean): void {
  calm = active;
}

export function setCalmStockExportRendering(active: boolean): void {
  stockExportRendering = active;
}

export function calmPresentationIsActive(): boolean {
  return calm;
}

export function calmPresentationHides(itemClass: CalmTranscriptClass): boolean {
  return calm && !stockExportRendering && !calmTranscriptClassIsVisible(itemClass);
}

// Pi builds every stock user row from three host-owned inputs: the settings-aware
// Markdown theme, the host output padding, and - from Pi 0.84 on - the Markdown
// transformer list (Pi's own mermaid transformer plus whatever extensions registered).
// Calm substitutes user rows in two places, the operational-user layout adapter and the
// legacy synthetic entry renderer below, and neither may drop one of those inputs. This
// module owns the one stock-constructor contract both build against.
export type UserMessageConstructorArgs = ConstructorParameters<typeof PiUserMessageComponent>;
// Pi 0.83 declares neither the transformer constructor argument nor the
// MarkdownTransformer type it holds, so the list is described locally instead of as
// UserMessageConstructorArgs[3] - indexing Pi's own tuple is an error against any
// pre-0.84 declaration. Nothing here inspects or calls a transformer; the value is only
// carried from the host to the stock constructor, so an opaque element type is the
// honest one and keeps a single source typechecking against both releases without
// sniffing the Pi version.
export type MarkdownTransformerList = readonly unknown[];
// Pi 0.83's declared constructor stops at outputPad, so the stock class is re-typed once
// with the 4th argument every release from 0.84 on accepts. Handing it to a 0.83 process
// is harmless - JS drops the extra argument, which is exactly the three-argument
// behavior that release had - and handing 0.84 an undefined there selects the same empty
// default a three-argument call would have received. Every argument after the text stays
// optional for the same reason: an absent host input selects Pi's own default rather
// than a constant copied out of one release.
export type StockUserMessageConstructor = new (
  text: UserMessageConstructorArgs[0],
  markdownTheme?: UserMessageConstructorArgs[1],
  outputPad?: number,
  markdownTransformers?: MarkdownTransformerList,
) => PiUserMessageComponent;

export function resolveStockUserMessageConstructor(): StockUserMessageConstructor {
  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi UserMessageComponent");
  }
  return UserMessageComponent as unknown as StockUserMessageConstructor;
}

// The subset of InteractiveMode a stock user row is built from. Every member is optional
// because pre-0.84 hosts have no getMarkdownTransformers and a missing input must fall
// through to Pi's own constructor default.
type CalmPiRowHost = {
  getMarkdownThemeWithSettings?(): UserMessageConstructorArgs[1];
  getMarkdownTransformers?(): MarkdownTransformerList;
  outputPad?: number;
};
type CalmPiRowHostCapture = {
  host: CalmPiRowHost | undefined;
};
type InteractiveModeCustomEntryPrototype = {
  addCustomEntryToChat(this: CalmPiRowHost, entry: unknown): void;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process. Holding the captured host in the registry rather than in
// module scope also survives an extension reload, where the first module instance keeps
// the installed patch and a later one still has to read the same live host.
const CALM_PI_ROW_HOST_CAPTURE = Symbol.for(
  "firstmate:calm-pi-row-host-capture:pi-0.84.1",
);

function calmPiRowHostRegistry(): typeof globalThis & {
  [key: symbol]: CalmPiRowHostCapture | undefined;
} {
  return globalThis as typeof globalThis & {
    [key: symbol]: CalmPiRowHostCapture | undefined;
  };
}

// Pi calls entry renderers as (entry, options, theme) and EntryRenderOptions carries only
// `expanded`, so the renderer below has no host to ask for those inputs. Exactly one
// method mounts these entries, InteractiveMode.addCustomEntryToChat, and it runs
// immediately before the renderer; the receiver it records stays valid for the later
// expansion redraws that re-run the renderer outside that frame. The patch observes only
// and always calls through, so a Pi that keeps the method renders identically with it.
export function installCalmPiRowHostCapture(): void {
  const registry = calmPiRowHostRegistry();
  if (registry[CALM_PI_ROW_HOST_CAPTURE]) return;

  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModeCustomEntryPrototype;
  const originalAddCustomEntryToChat = prototype.addCustomEntryToChat;
  if (typeof originalAddCustomEntryToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addCustomEntryToChat");
  }

  const capture: CalmPiRowHostCapture = { host: undefined };
  prototype.addCustomEntryToChat = function (entry: unknown): void {
    capture.host = this;
    originalAddCustomEntryToChat.call(this, entry);
  };
  registry[CALM_PI_ROW_HOST_CAPTURE] = capture;
}

export function registerFirstmateSyntheticPresentation(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<FirstmateSyntheticPresentation>(
    FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
    (entry) => {
      if (calmPresentationHides("synthetic-user")) return undefined;
      const data = entry.data;
      if (!data || typeof data.content !== "string") return undefined;
      const host = calmPiRowHostRegistry()[CALM_PI_ROW_HOST_CAPTURE]?.host;
      const StockUserMessageComponent = resolveStockUserMessageConstructor();
      return new StockUserMessageComponent(
        data.content,
        host?.getMarkdownThemeWithSettings?.() ?? getMarkdownTheme(),
        host?.outputPad,
        host?.getMarkdownTransformers?.(),
      );
    },
  );
}
