// Worker entry for BUG-189 shipped-entry proof. The shipped node-host worker
// (src/node-host/worker.ts) has no standalone main block, so this thin entry
// invokes its exported runNodeHostWorker — the real shipped entry function.
import { pathToFileURL } from "node:url";
import path from "node:path";

const openclawDir = process.env.OPENCLAW_DIR;
if (!openclawDir) {
  throw new Error("OPENCLAW_DIR is required");
}
const workerUrl = pathToFileURL(path.join(openclawDir, "src", "node-host", "worker.ts")).href;
const { runNodeHostWorker } = await import(workerUrl);

runNodeHostWorker().catch((error) => {
  console.error(`[worker-entry] runNodeHostWorker error: ${error?.stack || error}`);
  process.exit(1);
});
