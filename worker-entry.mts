// Worker entry for BUG-189 shipped-entry proof. The shipped node-host worker
// (src/node-host/worker.ts) has no standalone main block, so this thin entry
// invokes its exported runNodeHostWorker — the real shipped entry function.
import { register } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";

// Register the proof ESM loader BEFORE importing openclaw modules, so the loader
// can (a) rewrite node-invoke-progress.ts OLD/FIXED and inject the wall-clock
// rewind, and (b) inject the proof.hold duplex command into file-transfer.
if (process.env.PROOF_LOADER) {
  register(pathToFileURL(process.env.PROOF_LOADER).href);
  console.error(`[worker-entry] registered loader ${process.env.PROOF_LOADER}`);
}

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
