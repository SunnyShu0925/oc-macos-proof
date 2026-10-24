// Plan-Y recon: load the REAL built Control UI in WebKit, inject native embed + mock
// messageHandlers.openclawConversation, and observe how far startup gets / what the
// gateway does / whether the native bridge instantiates.
import { webkit } from "playwright";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const DIST = process.env.CONTROL_UI_DIST || path.resolve("dist/control-ui");

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".wasm": "application/wasm",
  ".webmanifest": "application/manifest+json",
  ".map": "application/json",
};

// Simple static server for the built UI.
function serve(dir) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let urlPath = decodeURIComponent(new URL(req.url, "http://x").pathname);
      if (urlPath === "/") urlPath = "/index.html";
      const file = path.join(dir, urlPath);
      if (!file.startsWith(path.resolve(dir))) {
        res.writeHead(403); res.end("forbidden"); return;
      }
      fs.readFile(file, (err, data) => {
        if (err) {
          // Fall back to index.html for SPA routes.
          if (!err.code || err.code === "ENOENT") {
            return fs.readFile(path.join(dir, "index.html"), (e2, d2) => {
              if (e2) { res.writeHead(404); res.end("nf"); return; }
              res.writeHead(200, { "content-type": "text/html" });
              res.end(d2);
            });
          }
          res.writeHead(404); res.end("nf"); return;
        }
        const ext = path.extname(file).toLowerCase();
        res.writeHead(200, { "content-type": MIME[ext] || "application/octet-stream" });
        res.end(data);
      });
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

async function main() {
  const server = await serve(DIST);
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  console.log(`[recon] serving ${DIST} at ${base}`);

  const browser = await webkit.launch({ headless: true });
  const page = await browser.newPage();

  const observed = [];
  const push = (tag, msg) => { observed.push(`[${tag}] ${msg}`); console.log(`[recon][${tag}] ${msg}`); };

  // Capture console + network
  page.on("console", (m) => push("console", `${m.type()}: ${m.text().slice(0, 300)}`));
  page.on("request", (r) => {
    const u = r.url();
    if (!u.startsWith(base + "/assets/") && !u.startsWith("data:")) {
      push("request", `${r.method()} ${u}`);
    }
  });
  page.on("response", (r) => {
    const u = r.url();
    if (!u.startsWith(base + "/assets/")) {
      push("response", `${r.status()} ${r.method()} ${u}`);
    }
  });
  page.on("requestfailed", (r) => push("requestfailed", `${r.failure()?.errorText} ${r.url()}`));

  // Inject native chrome + embed + mock handler BEFORE app scripts run.
  await page.addInitScript(() => {
    window.__OPENCLAW_NATIVE_EMBED__ = { platform: "macos", formFactor: "desktop", surface: "conversation" };
    window.__OPENCLAW_NATIVE_WEB_CHROME__ = true;
    const nativeMessages = [];
    window.__NATIVE_MESSAGES__ = nativeMessages;
    const handler = {
      postMessage: async (msg) => {
        nativeMessages.push(msg);
        console.log("[native-post]", JSON.stringify(msg).slice(0, 300));
        // Accept ready/state; a navigate command gets ok:true to simulate host ack.
        return { ok: true };
      },
    };
    Object.defineProperty(window, "webkit", {
      value: {
        messageHandlers: {
          openclawConversation: handler,
          openclawDeviceSettings: { postMessage: async () => ({ ok: true }) },
          openclawNotifications: { postMessage: async () => ({ ok: true }) },
          openclawGateways: { postMessage: async () => ({ ok: true }) },
        },
      },
      configurable: true,
    });
    window.addEventListener("error", (e) => console.log("[page-error]", e.message));
  });

  push("load", `navigating to ${base}/control/chat/main`);
  await page.goto(`${base}/control/chat/main`, { waitUntil: "domcontentloaded", timeout: 60000 });

  // Wait and sample state.
  for (const delay of [2000, 5000, 10000, 15000]) {
    await page.waitForTimeout(delay === 2000 ? 2000 : delay - [0, 2000, 5000, 10000][[2000, 5000, 10000, 15000].indexOf(delay)]);
    const info = await page.evaluate(() => {
      const w = window;
      return {
        readyState: document.readyState,
        location: location.href,
        title: document.title,
        nativeMessages: (w.__NATIVE_MESSAGES__ || []).map((m) => m && m.type),
        hasConversationDoc: !!(w.__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__),
        conversationDoc: w.__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__ ? JSON.stringify(w.__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__) : null,
        bodyText: (document.body ? document.body.innerText || document.body.textContent : "").slice(0, 200),
        hasChatPage: !!document.querySelector("openclaw-chat-page"),
        hasChatPane: !!document.querySelector("openclaw-chat-pane"),
        routeOutlet: !!w.__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__,
      };
    });
    console.log(`[recon][sample t=${delay}ms] ${JSON.stringify(info)}`);
  }

  // Dump all native messages
  const all = await page.evaluate(() => window.__NATIVE_MESSAGES__ || []);
  console.log(`[recon] total native messages: ${all.length}`);
  for (const m of all.slice(0, 20)) {
    console.log(`[recon][native-msg] ${JSON.stringify(m).slice(0, 300)}`);
  }

  await browser.close();
  server.close();
  process.exit(0);
}

main().catch((e) => { console.error("[recon][fatal]", e); process.exit(1); });
