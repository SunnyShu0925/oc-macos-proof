// Worker entry for BUG-189 shipped-entry proof.
//
// This process IS the forked node-host worker subprocess (parent-driver.mts forks
// this entry with `--import tsx`; the shipped worker has no standalone main block,
// so we call its exported runNodeHostWorker). It runs two things in order:
//
//  (1) CONTROLLED-SEQUENCE proof: the same write -> wall-clock-rewind ->
//      startHeartbeats sequence as proof-e2e, but executed INSIDE this shipped
//      worker process with the real NodeHostWorkerBridgeClient transport and real
//      timers. OLD (Date.now) must stall ~interval+skew (2250ms); FIXED
//      (performance.now) stays on the interval (250ms). Date.now is restored
//      before the shipped worker starts.
//
//  (2) SHIPPED WORKER: runNodeHostWorker — the real node-host worker entry, which
//      then performs a real gateway-connection + invoke dispatch and its recurring
//      progress heartbeat keeps firing (proof.hold parked) at the idle-derived
//      cadence.
//
// The OLD/FIXED heartbeat variant and proof.hold duplex command are injected
// directly into the CI checkout's source files by prepare-proof.mjs BEFORE this
// entry runs, so no ESM loader is needed here (the ESM loader is unreliable
// because the shipped runtime mutates process.env during module load).
import { pathToFileURL } from "node:url";
import path from "node:path";
import { performance } from "node:perf_hooks";

const openclawDir = process.env.OPENCLAW_DIR;
if (!openclawDir) {
  throw new Error("OPENCLAW_DIR is required");
}

// ---- (1) Controlled-sequence proof (real transport, real timers) ----
const progressUrl = pathToFileURL(path.join(openclawDir, "src", "node-host", "node-invoke-progress.ts")).href;
const wsUrl = pathToFileURL(path.join(openclawDir, "src", "node-host", "worker-support.ts")).href;
const [{ createNodeInvokeProgressWriter }, { NodeHostWorkerBridgeClient }] = await Promise.all([
  import(progressUrl),
  import(wsUrl),
]);

const frame = {
  id: "invoke-1",
  nodeId: "node-1",
  command: "test.duplex",
  paramsJSON: null,
  timeoutMs: 0,
  idempotencyKey: null,
};
const realDateNow = Date.now;
const skewMs = Number(process.env.PROOF_SKEW_MS || 2000);
const received = [];
const send = (f) => {
  received.push(f);
  client.handleResponse({ type: "gateway-response", generation: 1, id: f.id, ok: true, result: {} });
};
const client = new NodeHostWorkerBridgeClient(send);
client.setConnection(1, true);

const IDLE = 500; // heartbeat interval -> floor(500/2) = 250ms
const writer = createNodeInvokeProgressWriter({ client, frame, idleTimeoutMs: IDLE, onError: () => {} });

await writer.write("first chunk"); // stamps lastProgressAt on pre-rewind clock
Date.now = () => realDateNow() - skewMs; // rewind wall clock
const t0 = performance.now();
writer.startHeartbeats();
let elapsedToHeartbeat = null;
const deadline = performance.now() + 4_000;
while (performance.now() < deadline) {
  const heartbeat = received.find((f) => f.params?.chunk === "");
  if (heartbeat) {
    elapsedToHeartbeat = (performance.now() - t0).toFixed(0);
    break;
  }
  await new Promise((r) => setTimeout(r, 5));
}
writer.stop();
Date.now = realDateNow; // restore before shipped worker starts

console.log(
  `[controlled] variant=${process.env.PROOF_VARIANT} skew=${skewMs}ms firstHeartbeatElapsed=${elapsedToHeartbeat ?? "none>4000"}ms`,
);

// ---- (2) Shipped worker: real node-host worker entry ----
const workerUrl = pathToFileURL(path.join(openclawDir, "src", "node-host", "worker.ts")).href;
const { runNodeHostWorker } = await import(workerUrl);

runNodeHostWorker().catch((error) => {
  console.error(`[worker-entry] runNodeHostWorker error: ${error?.stack || error}`);
  process.exit(1);
});
