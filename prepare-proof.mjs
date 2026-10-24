// prepare-proof.mjs — BUG-189 shipped-entry proof, disk-injection variant.
//
// Rewrites the CI checkout's source on disk so the OLD/FIXED heartbeat variants
// and the proof.hold duplex command are injected WITHOUT relying on the flaky
// ESM loader (which is invalidated whenever any module sets process.env, as the
// shipped runtime does). The CI checkout is a throwaway worktree, so editing it
// does not touch the PR branch's git history; the PR itself is never modified.
//
//   PROOF_VARIANT=OLD|FIXED node prepare-proof.mjs
import fs from "node:fs";
import path from "node:path";

const openclawDir = process.env.OPENCLAW_DIR;
if (!openclawDir) throw new Error("OPENCLAW_DIR is required");
const variant = process.env.PROOF_VARIANT || "FIXED";
const skewMs = process.env.PROOF_SKEW_MS || "2000";
const armMs = process.env.PROOF_ARM_MS || "3000";

const progressPath = path.join(openclawDir, "src", "node-host", "node-invoke-progress.ts");
const fileTransferPath = path.join(openclawDir, "extensions", "file-transfer", "index.ts");
const nodeCommandsPath = path.join(openclawDir, "src", "infra", "node-commands.ts");

// ---- 0. Shrink the shipped duplex idle timeout so the heartbeat interval
// becomes the 250ms minimum (instead of the 5s max derived from the real 30s
// idle timeout). This only changes heartbeat cadence for observability; the
// OLD-vs-FIXED distinction (Date.now vs performance.now under a wall-clock
// rewind) is unchanged.
{
  let text = fs.readFileSync(nodeCommandsPath, "utf8");
  if (!text.includes("BUG-189 proof")) {
    text = text.replace(
      "export const NODE_DUPLEX_INVOKE_IDLE_TIMEOUT_MS = 30_000;",
      "export const NODE_DUPLEX_INVOKE_IDLE_TIMEOUT_MS = 500; /* BUG-189 proof: shrink heartbeat to 250ms min for observability */",
    );
    fs.writeFileSync(nodeCommandsPath, text);
    console.log(`[prepare-proof] shrank NODE_DUPLEX_INVOKE_IDLE_TIMEOUT_MS in ${nodeCommandsPath}`);
  }
}

// ---- 1. node-invoke-progress.ts: OLD/FIXED + wall-clock rewind ----
{
  let text = fs.readFileSync(progressPath, "utf8");
  const rewind = `
/* --- BUG-189 proof injection (begin) --- */
const __proofRealDateNow = globalThis.Date.now.bind(globalThis);
globalThis.__proofSkewApplied = false;
setTimeout(() => {
  if (!globalThis.__proofSkewApplied) {
    globalThis.__proofSkewApplied = true;
    globalThis.Date.now = () => __proofRealDateNow() - ${skewMs};
  }
}, ${armMs});
/* --- BUG-189 proof injection (end) --- */
`;
  if (variant === "OLD") {
    text = text.replace(/performance\.now\(\)/g, "Date.now()");
  }
  if (!text.includes("__proofSkewApplied")) {
    text = text.replace(
      "export function createNodeInvokeProgressWriter",
      rewind + "\nexport function createNodeInvokeProgressWriter",
    );
  }
  fs.writeFileSync(progressPath, text);
  console.log(`[prepare-proof] rewrote ${progressPath} (variant=${variant})`);
}

// ---- 2. file-transfer/index.ts: proof.hold duplex command ----
{
  let text = fs.readFileSync(fileTransferPath, "utf8");
  const injected = `\n  {\n    command: "proof.hold",\n    hasActiveWork: () => true,\n    duplex: true,\n    cap: "file",\n    dangerous: true,\n    handle: async () => {\n      await new Promise(() => {});\n    },\n  },\n`;
  if (!text.includes("command: \"proof.hold\"")) {
    text = text.replace(
      "const fileTransferNodeHostCommands: OpenClawPluginNodeHostCommand[] = [",
      "const fileTransferNodeHostCommands: OpenClawPluginNodeHostCommand[] = [" + injected,
    );
    fs.writeFileSync(fileTransferPath, text);
    console.log(`[prepare-proof] injected proof.hold into ${fileTransferPath}`);
  } else {
    console.log(`[prepare-proof] proof.hold already present in ${fileTransferPath}`);
  }
}
