import { mkdtemp, mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { webkit, type Page } from "playwright";
import { expect, it } from "vitest";
import { evaluateControlUiContext } from "../test-helpers/control-ui-e2e-context.ts";
import {
  controlUiSessionUrl,
  installMockGateway,
  startProductionControlUiE2eServer,
} from "../test-helpers/control-ui-e2e.ts";

type Probe = {
  messages: Array<Record<string, unknown>>;
  documentId: string;
  dateJumpMs: number;
  realDateNow: typeof Date.now;
  routerNavigations: number;
};

type Variant = {
  label: string;
  ok: boolean;
  error?: string;
};

const first = { agentId: "main", sessionKey: "agent:main:first" };
const second = { agentId: "main", sessionKey: "agent:main:second" };

async function installHost(page: Page, version: string) {
  await page.addInitScript((proofVersion) => {
    const realDateNow = Date.now;
    const probe: Probe = {
      messages: [],
      documentId: "",
      dateJumpMs: 0,
      realDateNow,
      routerNavigations: 0,
    };
    Object.assign(window, {
      __OPENCLAW_NATIVE_EMBED__: {
        platform: "macos",
        formFactor: "desktop",
        surface: "conversation",
      },
      __OPENCLAW_NATIVE_CONVERSATION__: { contract: 1 },
      __nativeConversationProof: probe,
      webkit: {
        messageHandlers: {
          openclawConversation: {
            postMessage(message: Record<string, unknown>) {
              probe.messages.push(message);
              if (message.type === "ready") {
                probe.documentId = String(message.documentId);
                console.log(`[proof] ${proofVersion} ready documentId=${probe.documentId}`);
              }
              return Promise.resolve({ ok: true });
            },
          },
        },
      },
    });
    Date.now = () => realDateNow() + probe.dateJumpMs;
    document.addEventListener("DOMContentLoaded", () => {
      document.documentElement.style.setProperty("--openclaw-native-titlebar-height", "52px");
    });
  }, version);
}

async function command(page: Page, target: typeof first, requestId: string, label: string) {
  const dispatched = await page.evaluate(
    ({ targetSession, id, variantLabel }) => {
      const state = Reflect.get(window, "__nativeConversationProof") as Probe;
      if (!state.documentId) {
        throw new Error("Native conversation bridge did not publish a documentId");
      }
      console.log(`[proof] ${variantLabel} dispatch native command requestId=${id}`);
      return window.dispatchEvent(
        new CustomEvent("openclaw:native-conversation-command", {
          detail: {
            contract: 1,
            documentId: state.documentId,
            requestId: id,
            type: "navigate",
            payload: targetSession,
          },
        }),
      );
    },
    { targetSession: target, id: requestId, variantLabel: label },
    { timeout: 10_000 },
  );
  if (!dispatched) {
    throw new Error(`Native conversation command ${requestId} was canceled`);
  }
}

async function result(page: Page, requestId: string) {
  return page.evaluate((id) => {
    const state = Reflect.get(window, "__nativeConversationProof") as Probe;
    return state.messages.find(
      (message) => message.type === "command-result" && message.requestId === id,
    );
  }, requestId);
}

async function stateAfterResult(page: Page, requestId: string) {
  return page.evaluate((id) => {
    const state = Reflect.get(window, "__nativeConversationProof") as Probe;
    const receiptIndex = state.messages.findIndex(
      (message) => message.type === "command-result" && message.requestId === id,
    );
    if (receiptIndex < 0) {
      return undefined;
    }
    return state.messages.slice(receiptIndex + 1).findLast((message) => message.type === "state")
      ?.context;
  }, requestId);
}

async function waitForResult(page: Page, requestId: string, timeoutMs = 15_000) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    const receipt = await result(page, requestId);
    if (receipt) {
      return receipt;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`No command receipt for ${requestId} within ${timeoutMs / 1_000}s`);
}

function sleep(ms: number) {
  return new Promise<void>((resolve) => {
    globalThis.setTimeout(resolve, ms);
  });
}

async function mountCase(variant: Variant, buildId: string) {
  const out = await mkdtemp(path.join(os.tmpdir(), "native-running-ui-"));
  await mkdir(out, { recursive: true });
  const server = await startProductionControlUiE2eServer(out, buildId);
  const browser = await webkit.launch();
  const context = await browser.newContext({
    serviceWorkers: "block",
    viewport: { width: 1280, height: 900 },
  });
  const page = await context.newPage();
  try {
    await installHost(page, variant.label);
    await installMockGateway(page, {
      serverBuildId: buildId,
      sessions: [first, second].map(({ sessionKey: key }) => ({
        key,
        label: key,
        kind: "direct",
      })),
    });
    await page.goto(controlUiSessionUrl(server.baseUrl, first.sessionKey));
    await page
      .locator(".chat-pane-cache__pane--visible .agent-chat__composer-combobox textarea")
      .waitFor();
    await page.waitForFunction(
      () => {
        const state = Reflect.get(window, "__nativeConversationProof") as Probe;
        const documentBinding = Reflect.get(window, "__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__");
        return (
          typeof state.documentId === "string" &&
          state.documentId.length > 0 &&
          typeof documentBinding === "object" &&
          documentBinding !== null &&
          Reflect.get(documentBinding, "documentId") === state.documentId
        );
      },
      undefined,
      { polling: 50, timeout: 20_000 },
    );
    console.log(
      `[proof] ${variant.label} bridge ready documentId=${await page.evaluate(
        () => (Reflect.get(window, "__nativeConversationProof") as Probe).documentId,
      )}`,
    );
    console.log(
      `[proof] ${variant.label} WebKit=${await browser.version()} initial = ${new URL(page.url()).pathname}`,
    );
    const initial = await evaluateControlUiContext(page, (applicationContext) => ({
      pathname: applicationContext.router.getState().location.pathname,
      pendingMatches: applicationContext.router.getState().pendingMatches.length,
      matches: applicationContext.router.getState().matches[0]?.status,
    }));
    expect(initial).toEqual({
      pathname: "/chat/main/first",
      pendingMatches: 0,
      matches: "success",
    });
    console.log(
      `[proof] ${variant.label} actual router settled route=${initial.pathname} pendingMatches=${initial.pendingMatches} match=${initial.matches}`,
    );
    await evaluateControlUiContext(page, (applicationContext) => {
      const original = applicationContext.navigateAndWait;
      Object.assign(applicationContext, {
        async navigateAndWait(
          routeId: Parameters<typeof original>[0],
          options?: Parameters<typeof original>[1],
        ) {
          const probeState = Reflect.get(window, "__nativeConversationProof") as Probe;
          probeState.routerNavigations += 1;
          const call = probeState.routerNavigations;
          const to = options?.pathname ?? "";
          console.log(`[proof] actual router navigate call=${call} to=${to}`);
          if (call === 1) {
            await new Promise<void>((resolve) => {
              Object.assign(probeState, {
                releaseFirstRouterNavigation: resolve,
              });
            });
          }
          return original.call(applicationContext, routeId, options);
        },
      });
    });
    await command(page, first, "first", variant.label);
    await page.waitForFunction(
      () => {
        const state = Reflect.get(window, "__nativeConversationProof") as Probe;
        return (
          state.routerNavigations === 1 &&
          typeof Reflect.get(state, "releaseFirstRouterNavigation") === "function"
        );
      },
      undefined,
      { polling: 25, timeout: 10_000 },
    );
    expect(await result(page, "first")).toBeUndefined();
    console.log(
      `[proof] ${variant.label} first command entered actual router; router calls=1 release=deferred`,
    );

    const fakeGatewayConsole: string[] = [];
    page.on("console", (message) => {
      const text = message.text();
      if (text.includes("fake WebSocket not implemented")) {
        fakeGatewayConsole.push(text);
      }
    });
    await command(page, second, "second", variant.label);
    const queuedAt = performance.now();
    const queued = await page.evaluate(async () => {
      const route = await new Promise<{
        calls: number;
        pathname: string;
        pendingMatches: number;
        matches: string | undefined;
      }>((resolve) => {
        const target = document.querySelector("openclaw-app-shell");
        if (!target) {
          throw new Error("Control UI shell is unavailable");
        }
        target.dispatchEvent(
          Object.assign(new Event("context-request", { bubbles: true, composed: true }), {
            context: "openclaw.application",
            contextTarget: target,
            subscribe: false,
            callback: (application: {
              router: {
                getState(): {
                  location: { pathname: string };
                  pendingMatches: unknown[];
                  matches: Array<{ status?: string }>;
                };
              };
            }) => {
              const state = application.router.getState();
              resolve({
                calls: (Reflect.get(window, "__nativeConversationProof") as Probe)
                  .routerNavigations,
                pathname: state.location.pathname,
                pendingMatches: state.pendingMatches.length,
                matches: state.matches[0]?.status,
              });
            },
          }),
        );
      });
      const state = Reflect.get(window, "__nativeConversationProof") as Probe;
      return {
        route,
        firstReceipt: state.messages.some(
          (message) => message.type === "command-result" && message.requestId === "first",
        ),
        secondReceipt: state.messages.some(
          (message) => message.type === "command-result" && message.requestId === "second",
        ),
      };
    });
    expect(queued).toEqual({
      route: {
        calls: 1,
        pathname: "/chat/main/first",
        pendingMatches: 0,
        matches: "success",
      },
      firstReceipt: false,
      secondReceipt: false,
    });
    console.log(
      `[proof] ${variant.label} second command queued behind first actual router call: router calls=1 first receipt=none second receipt=none route=${queued.route.pathname}`,
    );
    const jump = await page.evaluate(() => {
      const state = Reflect.get(window, "__nativeConversationProof") as Probe;
      const performanceBefore = performance.now();
      const wallBefore = Date.now();
      state.dateJumpMs = 60_000;
      return {
        wallDelta: Date.now() - wallBefore,
        performanceDelta: performance.now() - performanceBefore,
      };
    });
    console.log(
      `[proof] ${variant.label} wall jump Date.now delta=${jump.wallDelta}ms performance.now delta=${jump.performanceDelta.toFixed(1)}ms`,
    );
    expect(jump.wallDelta).toBe(60_000);
    expect(jump.performanceDelta).toBeLessThan(500);

    await sleep(1_500);
    const held = await page.evaluate(() => {
      const state = Reflect.get(window, "__nativeConversationProof") as Probe;
      return {
        routerCalls: state.routerNavigations,
        firstReceipt: state.messages.some(
          (message) => message.type === "command-result" && message.requestId === "first",
        ),
        secondReceipt: state.messages
          .filter((message) => message.type === "command-result" && message.requestId === "second")
          .map((message) => message.error ?? "ok"),
      };
    });
    expect(held).toEqual({
      routerCalls: 1,
      firstReceipt: false,
      secondReceipt: [],
    });
    const queueHeldMs = Math.round(performance.now() - queuedAt);
    expect(queueHeldMs).toBeGreaterThanOrEqual(1_450);
    const queuedRouter = await evaluateControlUiContext(page, (applicationContext) => ({
      calls: (Reflect.get(window, "__nativeConversationProof") as Probe).routerNavigations,
      pathname: applicationContext.router.getState().location.pathname,
    }));
    expect(queuedRouter).toEqual({ calls: 1, pathname: "/chat/main/first" });
    console.log(
      `[proof] ${variant.label} queue held ${queueHeldMs}ms: first actual router call still gated; second receipt=none`,
    );
    if (fakeGatewayConsole.length > 0) {
      console.log(
        `[proof] ${variant.label} browser gateway diagnostics=${JSON.stringify(fakeGatewayConsole)}`,
      );
    }
    expect(fakeGatewayConsole).toEqual([]);
    const released = await page.evaluate(() => {
      const state = Reflect.get(window, "__nativeConversationProof") as Probe;
      const release = Reflect.get(state, "releaseFirstRouterNavigation");
      if (typeof release !== "function") {
        throw new Error("First router navigation release is unavailable");
      }
      release();
      return true;
    });
    expect(released).toBe(true);
    const firstReceipt = await waitForResult(page, "first");
    expect(firstReceipt).toMatchObject({ ok: true });
    const firstRouter = await evaluateControlUiContext(page, (applicationContext) => {
      const route = applicationContext.router.getState();
      return {
        calls: (Reflect.get(window, "__nativeConversationProof") as Probe).routerNavigations,
        pathname: route.location.pathname,
        pendingMatches: route.pendingMatches.length,
        matches: route.matches[0]?.status,
      };
    });
    expect(firstRouter).toEqual({
      calls: 1,
      pathname: "/chat/main/first",
      pendingMatches: 0,
      matches: "success",
    });
    console.log(
      `[proof] ${variant.label} first receipt=${JSON.stringify(firstReceipt)} router calls=${firstRouter.calls} route=${firstRouter.pathname}`,
    );
    let secondReceipt: Record<string, unknown> | undefined;
    if (variant.ok) {
      await expect
        .poll(
          async () => {
            secondReceipt = (await result(page, "second")) as Record<string, unknown> | undefined;
            return secondReceipt;
          },
          { timeout: 10_000 },
        )
        .toBeDefined();
    } else {
      secondReceipt = (await result(page, "second")) as Record<string, unknown> | undefined;
    }
    expect(secondReceipt).toBeDefined();
    const receiptDelayMs = Math.round(performance.now() - queuedAt);
    console.log(
      `[proof] ${variant.label} second receipt=${JSON.stringify(secondReceipt)} ${receiptDelayMs}ms after queue`,
    );
    expect(secondReceipt).toMatchObject({ ok: variant.ok });
    if (variant.error) {
      expect(secondReceipt).toMatchObject({ error: variant.error });
    }
    if (variant.ok) {
      await expect.poll(() => page.url(), { timeout: 5_000 }).toContain(second.sessionKey);
      await expect.poll(() => stateAfterResult(page, "second"), { timeout: 5_000 }).toEqual(second);
      const assertFinal = expect
        .poll(
          () =>
            evaluateControlUiContext(page, (applicationContext) => {
              const route = applicationContext.router.getState();
              return {
                calls: (Reflect.get(window, "__nativeConversationProof") as Probe)
                  .routerNavigations,
                pathname: route.location.pathname,
                pendingMatches: route.pendingMatches.length,
                matches: route.matches[0]?.status,
                routeData: route.matches[0]?.data,
              };
            }),
          { timeout: 10_000 },
        )
        .toMatchObject({
          calls: 2,
          pathname: "/chat/main/second",
          pendingMatches: 0,
          matches: "success",
          routeData: { kind: "session", sessionKey: second.sessionKey, agentId: second.agentId },
        });
      await assertFinal;
      const finalRoute = await evaluateControlUiContext(page, (applicationContext) => {
        const route = applicationContext.router.getState();
        return {
          calls: (Reflect.get(window, "__nativeConversationProof") as Probe).routerNavigations,
          pathname: route.location.pathname,
          routeData: route.matches[0]?.data,
        };
      });
      expect(new URL(page.url()).pathname).toBe(finalRoute.pathname);
      const state = await stateAfterResult(page, "second");
      console.log(
        `[proof] ${variant.label} final actual UI route=${finalRoute.pathname} routerCalls=${finalRoute.calls} routeData=${JSON.stringify(finalRoute.routeData)} stateAfterReceipt=${JSON.stringify(state)}`,
      );
    }
    console.log(
      `VERDICT:${variant.label}:${variant.ok ? "SUCCEEDED" : "KILLED"}:${String(secondReceipt.error ?? "none")}`,
    );
  } finally {
    await context.close();
    await browser.close();
    await server.close();
    await rm(out, { recursive: true, force: true });
  }
}

const selectedVariant = process.env.PR182627_PROOF_VARIANT;

it("PROOF: queued native navigation crosses the running Control UI router after a wall-clock jump", async () => {
  const candidates: Array<Variant & { buildId: string }> = [
    { label: "post-fix", ok: true, buildId: "native-running-postfix" },
    { label: "pre-fix", ok: false, error: "navigate-timeout", buildId: "native-running-prefix" },
  ];
  const selected = selectedVariant
    ? candidates.filter((candidate) => candidate.label === selectedVariant)
    : candidates;
  if (selected.length === 0) {
    throw new Error(`Unknown PR182627_PROOF_VARIANT: ${selectedVariant}`);
  }
  for (const candidate of selected) {
    await mountCase(candidate, candidate.buildId);
  }
}, 180_000);
