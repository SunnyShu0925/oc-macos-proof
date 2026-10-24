// ESM loader for BUG-189 shipped-entry worker proof.
//
// 1) Restrict the node-host plugin registry to the lightweight file-transfer
//    plugin (provides the duplex `file.fetch` command that triggers the progress
//    writer's heartbeat). This is proof-environment plugin scoping, not a change
//    to heartbeat scheduling logic.
// 2) Variant injection into the shipped heartbeat owner (node-invoke-progress.ts):
//      OLD  -> rewrite performance.now() to Date.now() (pre-fix behavior)
//      FIXED-> keep performance.now() (post-fix behavior)
//    and inject a 2s wall-clock rewind (Date.now -= SKEW) ~1.2s after the worker
//    starts, so the bug scenario (NTP rewind mid-invoke) is exercised while
//    performance.now() stays monotonic.
export async function load(url, context, defaultLoad) {
  const src = await defaultLoad(url, context, defaultLoad);
  const text = Buffer.isBuffer(src.source) ? src.source.toString("utf8") : String(src.source);

  if (url.endsWith("src/node-host/plugin-node-host.ts")) {
    const modified = text.replace(
      "loadPluginRegistryHandle({",
      "loadPluginRegistryHandle({ onlyPluginIds: [\"file-transfer\"],",
    );
    return { ...src, source: modified };
  }

  if (url.endsWith("src/node-host/node-invoke-progress.ts")) {
    const variant = process.env.PROOF_VARIANT || "FIXED";
    const skewMs = process.env.PROOF_SKEW_MS || "2000";
    const armMs = process.env.PROOF_ARM_MS || "1200";
    const rewind = `
const __proofRealDateNow = globalThis.Date.now.bind(globalThis);
globalThis.__proofSkewApplied = false;
setTimeout(() => {
  if (!globalThis.__proofSkewApplied) {
    globalThis.__proofSkewApplied = true;
    globalThis.Date.now = () => __proofRealDateNow() - ${skewMs};
  }
}, ${armMs});
`;
    let modified = text;
    if (variant === "OLD") {
      modified = modified.replace(/performance\.now\(\)/g, "Date.now()");
    }
    if (!modified.includes("__proofSkewApplied")) {
      modified = modified.replace(
        "export function createNodeInvokeProgressWriter",
        rewind + "\nexport function createNodeInvokeProgressWriter",
      );
    }
    return { ...src, source: modified };
  }

  return src;
}
