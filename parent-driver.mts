// Parent driver for BUG-189 shipped-entry proof: forks the real node-host worker
// entry (runNodeHostWorker), drives real JSONL frames over its stdin
// (gateway-connection, then a duplex invoke), acks real gateway-requests over
// the bridge, and measures the real heartbeat cadence (empty progress chunks)
// under a 2s wall-clock rewind injected into the CI checkout source.
//
//   post-fix (performance.now): heartbeat gaps stay ~HEARTBEAT_INTERVAL_MS
//   pre-fix  (Date.now):        a gap of ~(interval + skew) appears after rewind
import { fork } from "node:child_process";
import { createInterface } from "node:readline";
import { performance } from "node:perf_hooks";

const WORKER_ENTRY = process.env.WORKER_ENTRY;
const VARIANT = process.env.PROOF_VARIANT || "FIXED";
const SKEW_MS = Number(process.env.PROOF_SKEW_MS || 2000);
const HEARTBEAT_INTERVAL_MS = Number(process.env.PROOF_INTERVAL_MS || 250);
const OBSERVE_MS = Number(process.env.PROOF_OBSERVE_MS || 6000);

const FRAME = {
  id: "invoke-bug189",
  nodeId: "node-1",
  // Proof-only duplex command injected by prepare-proof.mjs into file-transfer; its
  // handler parks forever, so the invocation stays alive and the progress writer
  // keeps emitting heartbeats for the whole observe window.
  command: "proof.hold",
  paramsJSON: null,
  timeoutMs: 60000,
};

function parse(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

async function main() {
  const child = fork(WORKER_ENTRY, [], {
    execArgv: ["--import", "tsx"],
    stdio: ["pipe", "pipe", "pipe", "ipc"],
    env: { ...process.env, PROOF_VARIANT: VARIANT, PROOF_SKEW_MS: String(SKEW_MS) },
  });

  const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const stderrBuf = [];
  child.stderr.on("data", (d) => stderrBuf.push(d.toString()));

  const heartbeatTimes = [];
  const sawReady = new Promise((res) => {
    rl.on("line", (line) => {
      const m = parse(line);
      if (m?.type === "ready") res(true);
    });
  });

  // Phase 1: wait for the real worker to publish its ready frame.
  await Promise.race([
    sawReady,
    new Promise((_, rej) => setTimeout(() => rej(new Error("worker not ready in 150s")), 150000)),
  ]);
  console.log(`[proof] worker ready (shipped node-host worker) variant=${VARIANT}`);

  // Ack every gateway-request so the worker's heartbeat request resolves, and
  // record empty progress chunks (heartbeats).
  rl.on("line", (line) => {
    const m = parse(line);
    if (!m) return;
    if (m.type === "gateway-request") {
      child.stdin.write(
        JSON.stringify({ type: "gateway-response", generation: 1, id: m.id, ok: true, result: {} }) +
          "\n",
      );
      if (m.method === "node.invoke.progress" && m.params?.chunk === "") {
        heartbeatTimes.push(performance.now());
      }
    }
  });

  // Phase 2: establish the connection, then send a duplex invoke.
  child.stdin.write(
    JSON.stringify({
      type: "gateway-connection",
      generation: 1,
      connection: { url: "ws://127.0.0.1:1", protocol: 3, capabilities: [] },
    }) + "\n",
  );
  await new Promise((r) => setTimeout(r, 800));
  child.stdin.write(JSON.stringify({ type: "invoke", generation: 1, request: FRAME }) + "\n");
  console.log(`[proof] duplex invoke sent (${FRAME.command})`);

  // Phase 3: observe heartbeat cadence.
  await new Promise((r) => setTimeout(r, OBSERVE_MS));

  // Cleanup
  child.stdin.write(JSON.stringify({ type: "stop" }) + "\n");
  child.kill();

  console.log(`RESULT[${VARIANT}] skew=${SKEW_MS}ms interval=${HEARTBEAT_INTERVAL_MS}ms`);
  console.log(`heartbeatCount=${heartbeatTimes.length}`);
  if (heartbeatTimes.length >= 2) {
    const gaps = [];
    for (let i = 1; i < heartbeatTimes.length; i++) {
      gaps.push(Math.round(heartbeatTimes[i] - heartbeatTimes[i - 1]));
    }
    console.log(`heartbeatGapsMs=${JSON.stringify(gaps)}`);
    const maxGap = Math.max(...gaps);
    const expected = HEARTBEAT_INTERVAL_MS;
    const inflated = gaps.filter((g) => g > expected + HEARTBEAT_INTERVAL_MS / 2);
    console.log(
      `inflatedGaps=${JSON.stringify(inflated)} (${
        inflated.length ? "KEEPALIVE DELAYED" : "stable cadence"
      })`,
    );
  } else {
    console.log("heartbeatGapsMs=[] (insufficient heartbeats)");
  }
  console.log(`--- worker stderr (tail) ---`);
  console.log(stderrBuf.join("").split("\n").slice(-25).join("\n"));
  process.exit(0);
}

main().catch((e) => {
  console.error("parent error:", e);
  process.exit(1);
});
