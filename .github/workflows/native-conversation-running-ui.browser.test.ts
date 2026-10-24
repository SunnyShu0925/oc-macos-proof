import { mkdtemp, mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { webkit, type Page } from "playwright";
import { expect, it } from "vitest";
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
};

const first = { agentId: "main", sessionKey: "agent:main:first" };
const second = { agentId: "main", sessionKey: "agent:main:second" };

async function installHost(page: Page, version: string) {
  await page.addInitScript((proofVersion) => {
    const realDateNow = Date.now;
    const probe = {
      messages: [],
      documentId: "",
      dateJumpMs: 0,
      realDateNow,
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
    // Keep the wall clock unchanged until the target command is queued.
    (window as unknown as { Date: DateConstructor }).Date.now = () =>
      realDateNow() + probe.dateJumpMs;
    document.addEventListener("DOMContentLoaded", () => {
      document.documentElement.style.setProperty("--openclaw-native-titlebar-height", "52px");
    });
  }, version);
}

async function command(page: Page, target: typeof first, requestId: string) {
  await page.evaluate(
    ({ targetSession, id }) => {
      const probe = (window as unknown as { __nativeConversationProof: Probe })
        .__nativeConversationProof;
      window.dispatchEvent(
        new CustomEvent("openclaw:native-conversation-command", {
          detail: {
            contract: 1,
            documentId: probe.documentId,
            requestId: id,
            type: "navigate",
            payload: targetSession,
          },
        }),
      );
    },
    { targetSession: target, id: requestId },
  );
}

async function result(page: Page, requestId: string) {
  return page.evaluate((id) => {
    const probe = (window as unknown as { __nativeConversationProof: Probe })
      .__nativeConversationProof;
    return probe.messages.find(
      (message) => message.type === "command-result" && message.requestId === id,
    );
  }, requestId);
}

async function stateRoute(page: Page, version: string) {
  return page.evaluate((proofVersion) => {
    const probe = (window as unknown as { __nativeConversationProof: Probe })
      .__nativeConversationProof;
    return {
      state: probe.messages.findLast((message) => message.type === "state")?.context ?? null,
      pathname: window.location.pathname,
      version: proofVersion,
    };
  }, version);
}

async function mountCase(version: "post-fix" | "pre-fix") {
  const out = await mkdtemp(path.join(os.tmpdir(), "native-running-ui-"));
  await mkdir(out, { recursive: true });
  const buildId = `native-running-${version}`;
  const server = await startProductionControlUiE2eServer(out, buildId);
  const browser = await webkit.launch();
  const context = await browser.newContext({ serviceWorkers: "block" });
  const page = await context.newPage();
  try {
    await installHost(page, version);
    const gateway = await installMockGateway(page, {
      serverBuildId: buildId,
      sessions: [first, second].map(({ sessionKey }) => ({
        key: sessionKey,
        label: sessionKey,
        kind: "direct",
      })),
    });
    await page.goto(controlUiSessionUrl(server.baseUrl, first.sessionKey));
    await page
      .locator(".chat-pane-cache__pane--visible .agent-chat__composer-combobox textarea")
      .waitFor();
    console.log(
      `[proof] ${version} WebKit=${browser.version()} URL=${page.url()} initial=${JSON.stringify(await stateRoute(page, version))}`,
    );
    // Defer the first navigation's real session load. The bridge must not reach
    // the router for the second command until this real router promise settles.
    const before = (await gateway.getRequests("chat.startup")).length;
    expect(await gateway.deferNext("chat.startup")).toBe(0);
    await command(page, first, "first");
    const firstRequest = await gateway.waitForRequest("chat.startup", { after: before });
    console.log(
      `[proof] ${version} router RPC #1 chat.startup params=${JSON.stringify(firstRequest.params)}`,
    );

    const callsBeforeSecond = (await gateway.getRequests("chat.startup")).length;
    await command(page, second, "second");
    await page.waitForTimeout(500);
    const routeBeforeRelease = await stateRoute(page, version);
    expect((await gateway.getRequests("chat.startup")).length).toBe(callsBeforeSecond);
    expect(await result(page, "second")).toBeUndefined();
    console.log(
      `[proof] ${version} queue: second command received; router calls=${callsBeforeSecond}; result absent; route=${JSON.stringify(routeBeforeRelease)}`,
    );

    const jump = await page.evaluate(() => {
      const probe = (window as unknown as { __nativeConversationProof: Probe })
        .__nativeConversationProof;
      const perfBefore = performance.now();
      probe.dateJumpMs = 60_000;
      return {
        wallNow: Date.now(),
        perfDelta: performance.now() - perfBefore,
      };
    });
    console.log(
      `[proof] ${version} wall clock +60000ms observed Date.now=${jump.wallNow}; performance.now delta=${jump.perfDelta}ms`,
    );

    await gateway.resolveDeferred("chat.startup");
    const secondRequest = await gateway.waitForRequest("chat.startup", {
      after: callsBeforeSecond,
    });
    console.log(
      `[proof] ${version} router RPC #2 chat.startup params=${JSON.stringify(secondRequest.params)}`,
    );
    await expect.poll(() => result(page, "second"), { timeout: 5_000 }).toBeDefined();
    const secondResult = await result(page, "second");
    const finalRoute = await stateRoute(page, version);
    console.log(
      `[proof] ${version} receipt=${JSON.stringify(secondResult)} route=${JSON.stringify(finalRoute)}`,
    );
    expect(await result(page, "first")).toBeDefined();
    return { version, result: secondResult, finalRoute };
  } finally {
    await context.close();
    await browser.close();
    await server.close();
    await rm(out, { recursive: true, force: true });
  }
}

it("PROOF: queued native navigation crosses the running Control UI router after a wall-clock jump", async () => {
  const post = await mountCase("post-fix");
  const pre = await mountCase("pre-fix");
  expect(post.result).toMatchObject({ ok: true });
  expect(pre.result).toMatchObject({ ok: false, error: "navigate-timeout" });
  console.log(`VERDICT:post-fix=${JSON.stringify(post.result)}`);
  console.log(`VERDICT:pre-fix=${JSON.stringify(pre.result)}`);
}, 120_000);
