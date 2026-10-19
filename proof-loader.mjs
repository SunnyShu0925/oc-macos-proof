// ESM loader for PR #175204 diamond proof v2.
// Intercepts two modules so the shipped `openclaw daemon install` CLI entry
// exercises bootstrapLaunchAgentOrThrow's pending-teardown retry with a
// controlled clock.
//
// 1. src/daemon/launchd-runtime.ts
//    VARIANT=OLD: replaces performance.now() with Date.now()+WALL_JUMP_MS so
//    the wall-clock deadline seed and remaining-budget read observe a wall-
//    clock step (NTP/manual-clock divergence). This is the buggy Date.now()
//    arithmetic. VARIANT=FIXED: untouched (monotonic, immune to skew).
//
// 2. src/daemon/launchd-exec.ts
//    Intercepts execLaunchctl so the `bootstrap` command returns a real EIO
//    ("Bootstrap failed: 5: Input/output error") that
//    isLaunchctlBootstrapPendingTeardown classifies as pending teardown.
//    Other launchctl commands (bootout/enable/print-disabled) run through the
//    real launchctl binary on the macOS runner. This reproduces the real
//    pending-teardown scenario (a bootout racing the next bootstrap) without
//    needing to time a real bootout teardown.

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
    // Inject a wrapper around execLaunchctl that forces bootstrap to return EIO.
    // The real launchctl binary still runs for every other command.
    const patched =
      source.replace(
        "export async function execLaunchctl(",
        `// PROOF: force bootstrap EIO to simulate pending teardown (real launchctl runs for other commands)
const __PROOF_FORCE_EIO = process.env.PROOF_FORCE_EIO === "1";
export async function execLaunchctl(__proofArgs, __proofBudget) {
  if (__PROOF_FORCE_EIO && __proofArgs[0] === "bootstrap") {
    return { code: 1, termination: "exit", stdout: "", stderr: "Bootstrap failed: 5: Input/output error" };
  }
  return __realExecLaunchctl(__proofArgs, __proofBudget);
}
const __realExecLaunchctl = async function execLaunchctl(`,
      );
    if (patched === source) {
      return result;
    }
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

  return result;
}
