// Occupy the Gateway TCP port as soon as the real Gateway job releases it, then
// keep it busy past the LaunchAgent stop port-release budget.
// Usage: node hold-port.mjs <port> <holdMs>
import net from "node:net";

const port = Number(process.argv[2] || 19990);
const holdMs = Number(process.argv[3] || 420_000);
const started = Date.now();
let boundAt = null;

const server = net.createServer((socket) => socket.destroy());

server.on("error", () => {
  if (boundAt === null) {
    setTimeout(tryBind, 10);
  }
});

function tryBind() {
  if (boundAt !== null) return;
  server.listen({ port, host: "127.0.0.1", exclusive: true });
}

server.on("listening", () => {
  boundAt = Date.now();
  console.log(`[hold-port] bound 127.0.0.1:${port} after ${boundAt - started}ms`);
});

tryBind();

setTimeout(() => {
  console.log("[hold-port] releasing port");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000);
}, holdMs);
