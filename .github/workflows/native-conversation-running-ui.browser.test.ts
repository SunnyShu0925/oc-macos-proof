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

async function command(page: Page, target: typeof first, requestId: string) {
  await page.evaluate(
    ({ targetSession, id }) => {
      const state = Reflect.get(window, "__nativeConversationProof") as Probe;
      window.dispatchEvent(
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
    { targetSession: target, id: requestId },
  );
}

async function result(page: Page, requestId: string) {
  return page.evaluate((id) => {
    const state = Reflect.get(window, "__nativeConversationProof") as Probe;
    return state.messages.find(
      (message) => message.type === "command-result" && message.requestId === id,
    );
  }, requestId);
}

async function waitForResult(page: Page, requestId: string) {
  const deadline = performance.now() + 20_000;
  while (performance.now() < deadline) {
    const receipt = await result(page, requestId);
    if (receipt) {
      return receipt;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`No command receipt for ${requestId} within 20s`);
}

function sessionKey(params: unknown) {
  if (typeof params !== "object" || params === null || !("sessionKey" in params)) {
    throw new Error("chat.startup has no sessionKey");
  }
  return String(params.sessionKey);
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
    const gateway = await installMockGateway(page, {
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
    console.log(
      `[proof] ${variant.label} WebKit=${await browser.version()} initial = ${new URL(page.url()).pathname}`,
    );

    const firstIndex = (await gateway.getRequests("chat.startup")).length;
    expect(await gateway.deferNext("chat.startup")).toBe(firstIndex);
    await command(page, first, "first");
    const firstRequest = await gateway.waitForRequest("chat.startup", { after: firstIndex });
    expect(sessionKey(firstRequest.params)).toBe(first.sessionKey);
    console.log(
      `[proof] ${variant.label} actual router RPC #${firstIndex + 1} chat.startup session=${sessionKey(firstRequest.params)} (held)`,
    );

    await command(page, second, "second");
    const queuedAt = performance.now();
    const receivedAt = Date.now();
    const leftoverBudgetMs = Math.max(0, 15_000 - (performance.now() - queuedAt));
    const queueSamples: Array<{
      atMs: number;
      calls: number;
      firstReceipt: boolean;
      secondReceipt: boolean;
    }> = [];
    const queueDeadline = performance.now() + 2_000;
    await expect
      .poll(
        async () => {
          const calls = (await gateway.getRequests("chat.startup")).length;
          const firstReceipt = Boolean(await result(page, "first"));
          const secondReceipt = Boolean(await result(page, "second"));
          queueSamples.push({
            atMs: Math.round(performance.now() - queuedAt),
            calls,
            firstReceipt,
            secondReceipt,
          });
          return { calls, firstReceipt, secondReceipt };
        },
        { timeout: Math.max(1, queueDeadline - performance.now()), interval: 50 },
      )
      .toStrictEqual({ calls: firstIndex + 1, firstReceipt: false, secondReceipt: false })
      .then(() => {
        console.log(
          `[proof] ${variant.label} queue held ${Math.round(performance.now() - queuedAt)}ms across ${queueSamples.length} samples: no second router RPC, no first/second receipt`,
        );
      });

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

    await gateway.resolveDeferred("chat.startup");
    const secondRequest = await gateway.waitForRequest("chat.startup", {
      after: firstIndex + 1,
    });
    expect(sessionKey(secondRequest.params)).toBe(second.sessionKey);
    console.log(
      `[proof] ${variant.label} actual router RPC #${firstIndex + 2} chat.startup session=${sessionKey(secondRequest.params)}`,
    );
    const secondReceipt = await waitForResult(page, "second");
    const receiptDelayMs = Math.round(performance.now() - queuedAt);
    const wallElapsedMs = Math.round(Date.now() - receivedAt);
    console.log(
      `[proof] ${variant.label} second receipt=${JSON.stringify(secondReceipt)} receiptDelay=${receiptDelayMs}ms wallElapsed=${wallElapsedMs}ms`,
    );
    const firstReceipt = await result(page, "first");
    expect(firstReceipt).toBeDefined();
    expect(secondReceipt).toMatchObject({ ok: variant.ok });
    if (variant.error) {
      expect(secondReceipt).toMatchObject({ error: variant.error });
    }
    if (variant.ok) {
      expect(receiptDelayMs).toBeLessThanOrEqual(leftoverBudgetMs + 2_000);
      await expect.poll(() => page.url(), { timeout: 20_000 }).toContain(second.sessionKey);
      expect(new URL(page.url()).pathname).toContain(second.sessionKey);
      console.log(`[proof] ${variant.label} final actual UI route=${new URL(page.url()).pathname}`);
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
