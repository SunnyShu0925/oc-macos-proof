import http from "node:http";

const port = Number(process.env.STUB_PORT || 18999);
http
  .createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
    });
    req.on("end", () => {
      if (req.url.startsWith("/v1/models")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ object: "list", data: [{ id: "stub-1", object: "model" }] }));
        return;
      }
      if (!req.url.includes("/chat/completions")) {
        res.writeHead(404);
        res.end("not found");
        return;
      }
      const id = "chatcmpl-stub-" + Date.now();
      const created = Math.floor(Date.now() / 1000);
      let parsed = {};
      try {
        parsed = JSON.parse(body || "{}");
      } catch {}
      const model = parsed.model || "stub-1";
      if (parsed.stream === false) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            id,
            object: "chat.completion",
            created,
            model,
            choices: [{ index: 0, message: { role: "assistant", content: "stub reply" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
          }),
        );
        return;
      }
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      const chunk = (delta, finish = null) =>
        "data: " +
        JSON.stringify({
          id,
          object: "chat.completion.chunk",
          created,
          model,
          choices: [{ index: 0, delta, finish_reason: finish }],
        }) +
        "\n\n";
      res.write(chunk({ role: "assistant", content: "" }));
      res.write(chunk({ content: "stub reply" }));
      res.write(chunk({}, "stop"));
      res.write("data: [DONE]\n\n");
      res.end();
    });
  })
  .listen(port, "127.0.0.1", () => console.log("stub model listening on " + port));
