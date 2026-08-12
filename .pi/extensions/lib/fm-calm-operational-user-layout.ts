// Verified against Pi 0.81.1, 0.82.0, 0.83.0, and 0.84.1, which add the ordinary-user
// spacer and row together via InteractiveMode.addMessageToChat. This adapter probes that
// exact method and throws if it is missing; fm-calm.ts catches that and skips only this
// adapter with a diagnostic instead of blocking Calm or Pi. It changes only that
// presentation and never message delivery.
//
// Pi 0.84 gave UserMessageComponent a 4th Markdown-transformer argument and feeds every
// stock user row this.getMarkdownTransformers() (the mermaid transformer plus whatever
// extensions registered). This adapter forwards that argument through the same host
// method so the row it substitutes keeps Pi's transformer output; the call is optional so
// Pi 0.83.0, which has neither the host method nor the constructor argument, still gets
// its own three-argument behavior.
import type { UserMessageComponent as PiUserMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";

type UserMessageConstructorArgs = ConstructorParameters<typeof PiUserMessageComponent>;
// The Markdown-transformer list Pi 0.84 hands its user rows. Pi 0.83 declares neither
// that constructor argument nor the MarkdownTransformer type it holds, so the list is
// described locally instead of as UserMessageConstructorArgs[3] - indexing Pi's own tuple
// is an error against any pre-0.84 declaration. Nothing here inspects or calls a
// transformer; the value is only carried from the host method to the stock constructor,
// so an opaque element type is the honest one and keeps a single source typechecking
// against both releases without sniffing the Pi version.
type MarkdownTransformerList = readonly unknown[];
// Pi 0.83's declared constructor stops at outputPad, so the stock class is re-typed once
// with the 4th argument every release from 0.84 on accepts. Handing it to a 0.83 process
// is harmless - JS drops the extra argument, which is exactly the three-argument
// behavior that release had - and handing 0.84 an undefined there selects the same empty
// default a three-argument call would have received.
type StockUserMessageConstructor = new (
  text: UserMessageConstructorArgs[0],
  markdownTheme: UserMessageConstructorArgs[1],
  outputPad: number,
  markdownTransformers: MarkdownTransformerList | undefined,
) => PiUserMessageComponent;
type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
};
type InteractiveModePresentation = {
  chatContainer: {
    children: unknown[];
    addChild(component: PiUserMessageComponent): void;
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getMarkdownThemeWithSettings(): UserMessageConstructorArgs[1];
  getMarkdownTransformers?(): MarkdownTransformerList;
  getUserMessageText(message: UserMessageLike): string;
  outputPad: number;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:pi-0.81.1",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string",
  );
}

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return (
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
    );
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi UserMessageComponent");
  }
  const StockUserMessageComponent =
    UserMessageComponent as unknown as StockUserMessageConstructor;
  class CalmOperationalUserMessageComponent extends StockUserMessageComponent {
    private readonly hasLeadingSpacer: boolean;

    constructor(
      text: UserMessageConstructorArgs[0],
      markdownTheme: UserMessageConstructorArgs[1],
      outputPad: number,
      markdownTransformers: MarkdownTransformerList | undefined,
      hasLeadingSpacer: boolean,
    ) {
      super(text, markdownTheme, outputPad, markdownTransformers);
      this.hasLeadingSpacer = hasLeadingSpacer;
    }

    override render(width: number): string[] {
      if (patch.hidesOperationalInput()) return [];
      const lines = super.render(width);
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    if (message.role !== "user" || !contentIsTextOnly(message.content)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const text = this.getUserMessageText(message);
    if (!text || !patch.isOperationalInput(text)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const component = new CalmOperationalUserMessageComponent(
      text,
      this.getMarkdownThemeWithSettings(),
      this.outputPad,
      this.getMarkdownTransformers?.(),
      this.chatContainer.children.length > 0,
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
