// ESM loader for PR #175204 diamond proof v2.
// Intercepts two modules so the shipped `openclaw daemon install` CLI entry
// exercises bootstrapLaunchAgentOrThrow's pending-teardown retry with a
// controlled clock.
//
// 1. src/daemon/launchd-exec.ts
//    Forces execLaunchctl("bootstrap",...) to return a real EIO that
//    isLaunchctlBootstrapPendingTeardown classifies as pending teardown.
//    Other launchctl commands run through the real launchctl binary.
//
// 2. src/daemon/launchd-runtime.ts
//    VARIANT=OLD: seed -> Date.now(), read -> Date.now() + WALL_JUMP_MS
//    (wall clock stepped between seed and read). VARIANT=FIXED: untouched.

const TARGET_RUNTIME = "/src/daemon/launchd-runtime.ts";
const TARGET_EXEC = "/src/daemon/launchd-exec.ts";

export async function resolve(specifier, context, nextResolve) {
  return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  if (result.format !== "module") {
    return result;
  }
  const source =
    typeof result.source === "string"
      ? result.source
      : Buffer.from(result.source).toString("utf8");

  if (url.endsWith(TARGET_EXEC)) {
    // Rename the real export and prepend a wrapper that forces bootstrap EIO.
    const realExport = "export async function execLaunchctl(";
    if (!source.includes(realExport)) return result;
    const patched = source.replace(
      realExport,
      `const __PROOF_FORCE_EIO = process.env.PROOF_FORCE_EIO === "1";
async function __realExecLaunchctl(`,
    ) + `
// PROOF wrapper: force bootstrap EIO to simulate pending teardown.
export async function execLaunchctl(args, budget) {
  if (__PROOF_FORCE_EIO && args[0] === "bootstrap") {
    return { code: 1, termination: "exit", stdout: "", stderr: "Bootstrap failed: 5: Input/output error" };
  }
  return __realExecLaunchctl(args, budget);
}
`;
    return { format: "module", source: patched };
  }

  if (url.endsWith(TARGET_RUNTIME)) {
    const variant = process.env.PROOF_VARIANT ?? "FIXED";
    const wallJumpMs = Number(process.env.WALL_JUMP_MS ?? "0");
    if (variant !== "OLD" || !wallJumpMs) {
      return result;
    }
    const patched = source
      .replace(
        /const teardownDeadline = performance\.now\(\) \+ LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;/,
        "const teardownDeadline = Date.now() + LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;",
      )
      .replace(
        /const remainingMs = teardownDeadline - performance\.now\(\);/,
        "const remainingMs = teardownDeadline - (Date.now() + WALL_JUMP_MS_VALUE);",
      );
    if (patched === source) {
      console.error(`[proof-loader] WARNING: launchd-runtime.ts sites not patched`);
      return result;
    }
    const injected =
      `const WALL_JUMP_MS_VALUE = ${wallJumpMs};\n` +
      `console.error("[proof-loader] VARIANT=${variant} WALL_JUMP_MS=${wallJumpMs} patched launchd-runtime.ts");\n` +
      patched;
    return { format: "module", source: injected };
  }

  return result;
}
