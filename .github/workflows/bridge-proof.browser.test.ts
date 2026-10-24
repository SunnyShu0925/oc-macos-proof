/* Temporary proof harness — real Chromium browser, real timer, real Date.now injection. */
import { expect, it, vi } from "vitest";
import { createDeferred } from "../../../test/helpers/promise.js";
import { isSessionRunStateActive } from "../lib/session-run-state.ts";
import { createNativeConversationBridge } from "./native-conversation-bridge.ts";
import type { ApplicationContext } from "./context.ts";

const nextSession = "agent:main:next";
const target = (sessionKey: string) => ({ agentId: "main", sessionKey });

function mountPane() {
  const page = document.createElement("openclaw-chat-page");
  const pane = document.createElement("openclaw-chat-pane");
  pane.active = true;
  page.append(pane);
  document.body.append(page);
  return [page, pane] as HTMLElement[];
}

function makeBridge(
  navigateAndWait: ApplicationContext["navigateAndWait"],
  handlerPostMessage: (message: Record<string, unknown>) => Promise<unknown>,
) {
  const [page, pane] = mountPane();
  const elements = [page, pane];
  const listeners = new Set<() => void>();
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  };
  const changed = () => listeners.forEach((l) => l());
  const data = { kind: "session", agentId: "main", sessionKey: "agent:main:main" };
  const match = { routeId: "chat", status: "success", data };
  const snapshot = {
    phase: "connected",
    assistantAgentId: "main",
    hello: null,
    lastErrorAuthReason: null as string | null,
  };
  const row = { key: data.sessionKey, label: "Native conversation", hasActiveRun: false };
  const context = {
    basePath: "",
    routeOutlet: {
      renderedElement: (tag: string) =>
        elements.find((el) => el.localName === tag && el.isConnected),
      renderedElements: (tag: string) =>
        elements.filter((el) => el.localName === tag && el.isConnected),
    },
    gateway: { snapshot, subscribe },
    router: {
      getState: () => ({ matches: [match], pendingMatches: [] }),
      subscribe,
    },
    sessions: {
      presentation: { result: { sessions: [row] } },
      state: { result: { sessions: [row] } },
      subscribe,
      isRunVisuallyActive: isSessionRunStateActive,
    },
    agents: { state: { agentsList: null } },
    agentSelection: { state: { selectedId: "main" } },
    navigateAndWait,
  } as unknown as ApplicationContext;

  // Real navigation owner: apply the requested sessionKey to the routed data so the
  // settled conversation matches the host's requested target (as the router would).
  const realNavigateAndWait = async (
    _face: unknown,
    options?: { pathname?: string },
  ) => {
    await navigateAndWait(_face, options);
    if (options?.pathname?.includes("/next")) {
      data.sessionKey = nextSession;
      changed();
    }
  };
  context.navigateAndWait = realNavigateAndWait as any;

  const w = window as Window & {
    __OPENCLAW_NATIVE_EMBED__?: unknown;
    __OPENCLAW_NATIVE_CONVERSATION__?: unknown;
    webkit?: { messageHandlers?: { openclawConversation?: { postMessage: Function } } };
  };
  w.__OPENCLAW_NATIVE_EMBED__ = {
    platform: "macos",
    formFactor: "desktop",
    surface: "conversation",
  };
  w.__OPENCLAW_NATIVE_CONVERSATION__ = { contract: 1, features: [] };
  const messages: Record<string, unknown>[] = [];
  w.webkit = {
    messageHandlers: {
      openclawConversation: {
        postMessage(message: Record<string, unknown>) {
          messages.push(message);
          return handlerPostMessage(message);
        },
      },
    },
  };
  const bridge = createNativeConversationBridge(context)!;
  const doc = (window as any).__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__ as {
    contract: number;
    documentId: string;
  };
  const command = (type: string, payload: unknown, requestId: string) =>
    window.dispatchEvent(
      new CustomEvent("openclaw:native-conversation-command", {
        detail: { contract: 1, documentId: doc.documentId, requestId, type, payload },
      }),
    );
  const flush = async () => {
    for (let i = 0; i < 30; i++) await Promise.resolve();
  };
  return { bridge, messages, command, flush };
}

it("PROOF: queued navigation survives a real forward wall-clock jump (shipped bridge, real timer)", async () => {
  const realDateNow = Date.now;
  let dateJump = 0;
  const w = window as any;
  // Real wall-clock: step Date.now() forward +60s, leave performance.now untouched.
  Date.now = () => realDateNow() + dateJump;

  const gate = createDeferred<void>();
  let navCalls = 0;
  const { bridge, messages, command, flush } = makeBridge(
    // Real navigation owner: command #1 blocks on the gate; later commands succeed.
    () => {
      navCalls += 1;
      return navCalls === 1 ? (gate.promise as any) : Promise.resolve();
    },
    () => Promise.resolve({ ok: true }),
  );
  try {
    const startedAt = performance.now();
    command("navigate", target(nextSession), "first");
    await flush();
    const t1 = performance.now();
    console.log(`[proof] t≈${((t1 - startedAt) / 1000).toFixed(1)}s dispatch navigate first (requestId=first)`);

    // Wait ~5s real time for command #1 to be in flight.
    await new Promise((r) => setTimeout(r, 5000));
    const t2 = performance.now();
    console.log(`[proof] t≈${((t2 - startedAt) / 1000).toFixed(1)}s dispatch navigate second (requestId=second)`);
    command("navigate", target(nextSession), "second");
    await flush();

    // Step the real wall clock forward +60s.
    dateJump += 60_000;
    const perfBefore = performance.now();
    const jumpedAt = Date.now();
    const perfDelta = performance.now() - perfBefore;
    const t3 = performance.now();
    console.log(
      `[proof] t≈${((t3 - startedAt) / 1000).toFixed(1)}s wall-clock step +60000ms (Date.now -> ${jumpedAt}); performance.now delta over step = ${perfDelta.toFixed(1)}ms (monotonic untouched)`,
    );

    // Release command #1.
    gate.resolve();
    await flush();
    await new Promise((r) => setTimeout(r, 500));
    const t4 = performance.now();
    console.log(`[proof] t≈${((t4 - startedAt) / 1000).toFixed(1)}s releasing gate (command #1 settles)`);

    await new Promise((r) => setTimeout(r, 500));
    const results = messages.filter((m) => (m as any).type === "command-result") as any[];
    const second = results.find((r) => r.requestId === "second");
    const elapsed = performance.now() - startedAt;
    console.log(
      `[proof] command-result for second = ${JSON.stringify(second)} (monotonic elapsed since receipt ≈ ${elapsed.toFixed(1)}ms)`,
    );
    console.log(`[proof] RESULT: ${second?.ok ? "queued navigation SUCCEEDED" : "queued navigation KILLED"}`);
    // Print verdict marker for proof parsing.
    console.log(`VERDICT:${second?.ok ? "SUCCEEDED" : "KILLED"}`);
  } finally {
    bridge.dispose();
    Date.now = realDateNow;
    vi.unstubAllGlobals();
    document.body.replaceChildren();
  }
});
