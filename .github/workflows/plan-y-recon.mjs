// Plan-Y recon: load the REAL built Control UI in WebKit, inject native embed + mock
// messageHandlers.openclawConversation, and observe how far startup gets / what the
// gateway does / whether the native bridge instantiates.
import { webkit } from "playwright";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const DIST = process.env.CONTROL_UI_DIST || path.resolve("dist/control-ui");

const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml",
  ".png": "image/png", ".wasm": "application/wasm", ".webmanifest": "application/manifest+json",
  ".map": "application/json",
};

function serve(dirArg) {
  const dir = path.resolve(dirArg);
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let urlPath = decodeURIComponent(new URL(req.url, "http://x").pathname);
      if (urlPath === "/") urlPath = "/index.html";
      // Strip the gateway mount prefix used by the built SPA (base=/control/chat or /control).
      let stripped = urlPath.replace(/^\/control\/chat\//, "/").replace(/^\/control\//, "/");
      if (stripped.includes("..")) { console.log(`[recon][server-403] ${urlPath}`); res.writeHead(403); res.end(); return; }
      const file = path.join(dir, stripped);
      if (!file.startsWith(path.resolve(dir))) { res.writeHead(403); res.end(); return; }
      fs.readFile(file, (err, data) => {
        if (err) {
          const ext = path.extname(stripped).toLowerCase();
          if (err.code === "ENOENT" && MIME[ext]) { res.writeHead(404); res.end("nf"); return; }
          // SPA fallback for non-asset paths.
          return fs.readFile(path.join(dir, "index.html"), (e2, d2) => {
            if (e2) { res.writeHead(404); res.end("nf"); return; }
            res.writeHead(200, { "content-type": "text/html" }); res.end(d2);
          });
        }
        const ext = path.extname(stripped).toLowerCase();
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

  page.on("console", (m) => console.log(`[recon][console ${m.type()}] ${m.text().slice(0, 300)}`));
  page.on("request", (r) => {
    const u = r.url();
    if (!u.startsWith(base + "/assets/") && !u.startsWith("data:")) {
      console.log(`[recon][request] ${r.method()} ${u}`);
    }
  });
  page.on("requestfailed", (r) => console.log(`[recon][requestfailed] ${r.failure()?.errorText} ${r.url()}`));

  await page.addInitScript(() => {
    window.__OPENCLAW_NATIVE_EMBED__ = { platform: "macos", formFactor: "desktop", surface: "conversation" };
    window.__OPENCLAW_NATIVE_WEB_CHROME__ = true;
    const nativeMessages = [];
    window.__NATIVE_MESSAGES__ = nativeMessages;
    window.__MOCK_NATIVE__ = {
      postMessage: async (msg) => {
        nativeMessages.push(msg);
        console.log("[native-post]", JSON.stringify(msg).slice(0, 300));
        return { ok: true };
      },
    };
    Object.defineProperty(window, "webkit", {
      value: {
        messageHandlers: {
          openclawConversation: window.__MOCK_NATIVE__,
          openclawDeviceSettings: window.__MOCK_NATIVE__,
          openclawNotifications: window.__MOCK_NATIVE__,
          openclawGateways: window.__MOCK_NATIVE__,
          openclawWindowDrag: { postMessage: async () => ({ ok: true }) },
        },
      },
      configurable: true,
    });
    window.addEventListener("error", (e) => console.log("[page-error]", e.message));
  });

  console.log(`[recon][load] navigating to ${base}/control/chat/main`);
  await page.goto(`${base}/control/chat/main`, { waitUntil: "domcontentloaded", timeout: 60000 });

  for (const delay of [2000, 5000, 10000]) {
    await page.waitForTimeout(delay === 2000 ? 2000 : delay === 5000 ? 3000 : 5000);
    const info = await page.evaluate(() => {
      const w = window;
      const body = document.body ? (document.body.innerText || document.body.textContent || "") : "";
      return {
        readyState: document.readyState,
        location: location.href,
        title: document.title,
        nativeMessages: (w.__NATIVE_MESSAGES__ || []).map((m) => m && m.type),
        hasConversationDoc: !!(w.__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__),
        conversationDoc: w.__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__
          ? JSON.stringify(w.__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__).slice(0, 200) : null,
        bodyText: body.slice(0, 200),
      };
    });
    console.log(`[recon][sample t=${delay}ms] ${JSON.stringify(info)}`);
  }

  const all = await page.evaluate(() => window.__NATIVE_MESSAGES__ || []);
  console.log(`[recon] total native messages: ${all.length}`);
  for (const m of all.slice(0, 25)) {
    console.log(`[recon][native-msg] ${JSON.stringify(m).slice(0, 300)}`);
  }

  await browser.close();
  server.close();
  process.exit(0);
}

main().catch((e) => { console.error("[recon][fatal]", e); process.exit(1); });
