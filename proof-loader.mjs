// ESM loader for PR #175204 diamond proof v2.
// Intercepts src/daemon/launchd-runtime.ts so the shipped `openclaw daemon install`
// CLI entry exercises bootstrapLaunchAgentOrThrow with a controlled clock.
//
// VARIANT=OLD: replaces performance.now() with Date.now() + WALL_JUMP_MS so the
//   wall-clock deadline seed and remaining-budget read observe a wall-clock step
//   (NTP/manual-clock divergence). This is the buggy Date.now() arithmetic.
// VARIANT=FIXED: leaves performance.now() untouched (monotonic, immune to skew).
//
// Only launchd-runtime.ts is patched; the rest of the shipped CLI runs unmodified,
// including the real launchctl child process transport.

const TARGET = "/src/daemon/launchd-runtime.ts";

export async function resolve(specifier, context, nextResolve) {
  return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  if (!url.endsWith(TARGET) || result.format !== "module") {
    return result;
  }
  const variant = process.env.PROOF_VARIANT ?? "FIXED";
  const wallJumpMs = Number(process.env.WALL_JUMP_MS ?? "0");
  if (variant !== "OLD" || !wallJumpMs) {
    return result;
  }
  const source = typeof result.source === "string"
    ? result.source
    : Buffer.from(result.source).toString("utf8");
  // Replace the two performance.now() calls in bootstrapLaunchAgentOrThrow:
  //   const teardownDeadline = performance.now() + LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;
  //   const remainingMs = teardownDeadline - performance.now();
  // OLD variant: both read Date.now() + wallJumpMs instead of the monotonic clock.
  const patched = source
    .replace(
      /const teardownDeadline = performance\.now\(\) \+ LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;/,
      "const teardownDeadline = Date.now() + WALL_JUMP_MS_VALUE + LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;",
    )
    .replace(
      /const remainingMs = teardownDeadline - performance\.now\(\);/,
      "const remainingMs = teardownDeadline - (Date.now() + WALL_JUMP_MS_VALUE);",
    );
  if (patched === source) {
    console.error(`[proof-loader] WARNING: no performance.now() sites patched in ${url}`);
    return result;
  }
  const injected =
    `const WALL_JUMP_MS_VALUE = ${wallJumpMs};\n` +
    `console.error("[proof-loader] VARIANT=${variant} WALL_JUMP_MS=${wallJumpMs} patched launchd-runtime.ts");\n` +
    patched;
  return { format: "module", source: injected };
}
