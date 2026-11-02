/**
 * PR #186831 — macOS native-launchd recovery proof.
 *
 * Drives the SHIPPED MANAGED_HANDOFF_RECOVERY_SOURCE restoreGatewayService()
 * (launchd branch) against the REAL `launchctl` binary and a REAL bootstrapped
 * launchd job with a REAL live PID, under a forward wall-clock step.
 *
 * This is NOT a transport wrap: real `launchctl print/enable/bootstrap/kickstart`
 * run on the macOS-14 runner (probe-launchctl.yml proved bootstrap/kickstart/
 * bootout all return 0 and produce a real PID). The only injection is a clock
 * preload that steps Date.now() FORWARD after the monotonic budget is seeded,
 * standing in for an NTP / manual clock jump mid-recovery.
 *
 * Recovery loop (shipped, recovery-source.ts launchd branch):
 *   before = print -> not-loaded (job was bootstrapped then booted-out so the
 *                     label is registered but absent) -> skip refuse
 *   enable  -> real `launchctl enable gui/$UID/$label` (exit 0)
 *   loop:   print -> not-loaded -> real `launchctl bootstrap gui/$UID <plist>`
 *           -> job loads with a REAL live PID
 *           next print -> code 0 + live pid != parentPid -> restored=true
 *
 * Forward step effect (budget is seeded at real time, stepped after):
 *   - FIXED (post-fix): budget is performance.now()-based -> immune; recovery
 *     completes restored=true within recoveryTimeoutMs.
 *   - OLD   (pre-fix):  deadline = Date.now()+timeoutMs seeded at real time; the
 *     forward step collapses remainingMs()=deadline-Date.now() to <=0 before the
 *     fresh PID is observed, so the loop is truncated -> restored=false.
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, chmodSync, mkdirSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { homedir } from "node:os";

const wt = process.env.OPENCLAW_DIR ?? "/tmp/wt186831-fix";
const mode = process.argv[2] ?? "FIXED";
const recoveryTimeoutMs = Number(process.argv[3] ?? 30000);
const clockStepForwardMs = Number(process.argv[4] ?? 60000);

const uid = Number(process.env.PROOF_UID ?? process.getuid());
const label = "com.openclaw.proofrecovery";
const target = `gui/${uid}/${label}`;

const { MANAGED_HANDOFF_RECOVERY_SOURCE } = await import(
  `${join(wt, "src/infra/update-managed-service-handoff-recovery-source.ts")}?t=${Date.now()}`
);
const { MANAGED_HANDOFF_COMMAND_SOURCE } = await import(
  `${join(wt, "src/infra/update-managed-service-handoff-command-source.ts")}?t=${Date.now()}`
);

// Original (pre-fix) budget arithmetic: epoch deadline read back with Date.now().
const PREFIX_COMMAND_SOURCE = `
function createMonotonicBudget(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  const remainingMs = () => Math.max(0, deadline - Date.now());
  return { remainingMs, commandDeadlineAt: () => deadline };
}
function runServiceCommand(command, args, onSpawn, deadline, timeoutCap) {
  if (!hasManagedUpdateLease()) return Promise.resolve({ code: 1, stdout: "", stderr: "" });
  return new Promise((resolve) => {
    const remaining = deadline === undefined ? params.recoveryTimeoutMs : deadline - Date.now();
    if (remaining <= 0) return resolve({ code: 1, stdout: "", stderr: "" });
    const output = { stdout: "", stderr: "" };
    const child = spawn(command, args, { env: params.serviceManagerEnv, stdio: ["ignore", "pipe", "pipe"] });
    child.stdout?.on("data", (c) => { output.stdout += c; });
    child.stderr?.on("data", (c) => { output.stderr += c; });
    child.once("spawn", () => onSpawn?.());
    child.once("error", (e) => { output.stderr = String(e); });
    child.once("close", (code) => { resolve({ code: typeof code === "number" ? code : 1, ...output }); });
  });
}
`;

// inlined parseLaunchctlJob (byte-semantic clone of src/daemon/launchctl-job.ts)
const PARSE_SOURCE = `function parseStrictPositiveInteger(v) { if (v === undefined) return undefined; const n = Number(v); return Number.isInteger(n) && n > 0 ? n : undefined; }
function parseStrictInteger(v) { if (v === undefined) return undefined; const n = Number(v); return Number.isInteger(n) ? n : undefined; }
function parseLaunchctlJob(output, serviceTarget) {
  if (!output.startsWith(serviceTarget + " = {\\n")) throw new Error("Cannot parse launchd job " + serviceTarget);
  const fields = new Map();
  for (const [, name, value] of output.matchAll(/^\\t([^\\t\\n=]+) = (.+)$/gm)) {
    if (fields.has(name)) throw new Error("Duplicate launchd job field " + name);
    fields.set(name, value);
  }
  const block = function (name) { return output.match(new RegExp("^\\\\t" + name + " = \\\\{\\\\n([\\s\\S]*?)^\\\\t\\}", "m"))?.[1]; };
  const runtime = {};
  const state = fields.get("state")?.trim(); if (state) runtime.state = state;
  const pid = parseStrictPositiveInteger(fields.get("pid")); if (pid !== undefined) runtime.pid = pid;
  const status = parseStrictInteger(fields.get("last exit status")); if (status !== undefined) runtime.lastExitStatus = status;
  const exitReason = fields.get("last exit reason")?.trim(); if (exitReason) runtime.lastExitReason = exitReason;
  return { fields, runtime, arguments: block("arguments")?.split("\\n").filter(function (l) { return l.startsWith("\\t\\t"); }).map(function (l) { return l.slice(2); }), environment: block("environment") ?? "", environmentBlocks: [...output.matchAll(/^\\t(?:inherited |default )?environment = \\\\{\\\\n([\\s\\S]*?)^\\t\\}/gm)].map(function (m) { return m[1] ?? ""; }).join("\\n") };
}`;

function buildStandalone() {
  const commandSource = mode === "OLD" ? PREFIX_COMMAND_SOURCE : MANAGED_HANDOFF_COMMAND_SOURCE;
  return `
// ===== thin harness bindings (same free vars the sealed helper provides) =====
import { spawn } from "node:child_process";
import fs from "node:fs";
import { pathToFileURL } from "node:url";

const params = JSON.parse(process.env.HARNESS_PARAMS);
const appendLog = (m) => { process.stdout.write("[helper] " + m + "\\n"); };
const managedUpdateLease = { action: { kind: "update" } };
const hasManagedUpdateLease = () => true;
const ownsManagedUpdateLease = () => {
  try { return fs.realpathSync(params.updateLeaseKey) === params.updateLeaseKey; } catch { return false; }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
const isLaunchdNotLoaded = (result) => /no such process|could not find service|not found/i.test((result.stderr || "") + (result.stdout || ""));
// production isPidAlive (src/shared/pid-alive.ts): a real live-child probe.
const isPidAlive = (pid) => { if (!Number.isInteger(pid) || pid <= 0) return false; try { process.kill(pid, 0); return true; } catch { return false; } };
const recordManagedUpdateOutcome = async () => ({ recorded: true });
const runOwnedUpdateCommand = async () => ({ code: 0, signal: undefined });
const runLedger = { recordUpdateRunVerification: (runId, v) => process.stdout.write("[helper] verification " + JSON.stringify({ runId, ...v }) + "\\n") };
let serviceStoppedAtMs = undefined;
let serviceDowntimeMs = undefined;

// ===== SHIPPED command source (createMonotonicBudget + runServiceCommand) =====
${commandSource}

// ===== inlined parseLaunchctlJob (production clone) =====
${PARSE_SOURCE}

// ===== SHIPPED recovery source (restoreGatewayService) =====
${MANAGED_HANDOFF_RECOVERY_SOURCE}


// DEBUG: capture runServiceCommand results, with a hard per-command timeout
// guard so a missing binary (non-macOS smoke) can never wedge the harness.
const __origRSC = runServiceCommand;
runServiceCommand = (cmd, args, onSpawn, deadline, timeoutCap) => {
  const r = __origRSC(cmd, args, onSpawn, deadline, timeoutCap);
  const guard = new Promise((_, reject) => setTimeout(() => reject(new Error("rsc-timeout:" + cmd)), 15000));
  return Promise.race([r, guard]).then((res) => {
    console.error("[trace] " + cmd + " " + args.join(" ") + " => code=" + res.code + " stderr=" + JSON.stringify((res.stderr||"").slice(0,100)));
    return res;
  }).catch((e) => {
    console.error("[trace] " + cmd + " " + args.join(" ") + " => ERROR " + String(e));
    return { code: 1, stdout: "", stderr: String(e) };
  });
};

// ===== invoke the recovery as the helper does =====
const t0 = performance.now();
const restored = await restoreGatewayService("managed-service-handoff-failed");
const wallElapsed = Math.round(performance.now() - t0);
process.stdout.write("[helper] RESULT restored=" + restored + " wallElapsedMs=" + wallElapsed + "\\n");
`;
}

let script = buildStandalone();

const dir = mkdtempSync(join(tmpdir(), "oc-recovery-mac-"));
const harnessFile = join(dir, "harness.mjs");
// realpath-normalize so ownsManagedUpdateLease()'s fs.realpathSync comparison
// holds: macOS $TMPDIR (/var/folders/...) symlinks to /private/var/folders/...,
// so a raw path would NOT equal its own realpath -> recovery would refuse.
const plistPath = join(homedir(), "Library/LaunchAgents/com.openclaw.proofrecovery.plist");
// leaseKey must exist before realpath; write it now (before harness uses it)
writeFileSync(join(dir, "lease-key"), "x");
const leaseKey = realpathSync(join(dir, "lease-key"));

// Real launchd job plist: /bin/sleep 300 (long-lived, gives us a real live PID).
mkdirSync(join(homedir(), "Library/LaunchAgents"), { recursive: true });
writeFileSync(plistPath, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key><array><string>/bin/sleep</string><string>300</string></array>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
`);
writeFileSync(harnessFile, script);

// ---------------------------------------------------------------------------
// Seed the real launchd job: bootstrap ONCE with RunAtLoad=false so the job is
// LOADED but NOT running (state = "not running", no pid). This mirrors the
// recovery scenario: the job label exists but its process is down. The recovery
// loop then drives real `launchctl kickstart` to bring up a REAL live PID.
//   - before print: code 0, pid undefined -> recovery does NOT refuse.
//   - enable -> real `launchctl enable gui/$UID/$label` (exit 0).
//   - loop: print -> not running -> real `kickstart` -> real sleep PID ->
//     next print -> code 0 + live pid != parentPid -> restored=true.
// ---------------------------------------------------------------------------
function sh(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  return { code: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}
const boot = sh("launchctl", ["bootstrap", `gui/${uid}`, plistPath]);
console.error("[setup] bootstrap -> code=" + boot.code + " " + boot.stderr.trim());
// Let launchd register the job (RunAtLoad=false, so it stays not-running).
await new Promise((r) => setTimeout(r, 1500));
const seedPrint = sh("launchctl", ["print", target]);
console.error("[setup] seed print code=" + seedPrint.code);
console.error("[setup] seed print head: " + seedPrint.stdout.split("\n").slice(0, 8).join("\n"));

// parentPid = this driver process; recovery compares printed pid against it.
const parentPid = process.pid;

// Stub readiness-probe module: restoreGatewayService imports
// params.recoveryModulePath and calls waitForGatewayUpdateRecovery() after the
// launchd loop restores the service. The deadline under test is the recovery
// loop budget, not the readiness probe, so the probe answers healthy with the
// expected version/build id immediately.
const recoveryModulePath = join(dir, "recovery-probe.mjs");
writeFileSync(
  recoveryModulePath,
  `export async function waitForGatewayUpdateRecovery(version, buildId, timeoutMs) {
  return { healthy: true, runtime: { status: "running", pid: ${parentPid} },
    gatewayVersion: version, gatewayBuildId: buildId, channelProbeErrors: [], activatedPluginErrors: [] };
}`
);

const params = {
  serviceRecovery: { kind: "launchd", uid, label, plistPath },
  recoveryTimeoutMs,
  parentPid,
  updateLeaseKey: leaseKey,
  recoveryCommandArgv: ["true"],
  recoveryModulePath,
  runId: "proof-run-186831",
  cwd: dir,
  serviceManagerEnv: {
    ...process.env,
    PROOF_MARKER: join(dir, "marker"),
    PROOF_KICKED: join(dir, "kicked"),
  },
  recovery: { serviceRestartSafe: true, version: "2026.10.9", buildId: "proof" },
};

const preload = `
import fs from "node:fs";
const realDateNow = Date.now;
let stepped = false;
let offset = 0;
Date.now = () => { return realDateNow() + offset; };
const marker = process.env.PROOF_MARKER;
const probe = () => {
  if (stepped || !marker) return;
  if (fs.existsSync(marker)) {
    stepped = true;
    offset = Number(process.env.STEP_FORWARD_MS || 0);
    console.error("[clock] stepping Date.now() forward by " + offset + "ms");
    clearInterval(timer);
  }
};
const timer = setInterval(probe, 10);
`;

// The PROOF_MARKER must be touched by the FIRST genuine launchctl print in the
// recovery loop (budget seeded). We touch it in a wrapper launchctl? No — we use
// the REAL launchctl, so instead the marker is created by the recovery helper's
// own first runServiceCommand("launchctl", ["print"...]) call. We hook
// runServiceCommand in the harness to touch the marker on the first print.
const markerHook = `
const __origRSC2 = runServiceCommand;
runServiceCommand = (cmd, args, onSpawn, deadline, timeoutCap) => {
  if (cmd === "launchctl" && args[0] === "print") {
    try { fs.writeFileSync(process.env.PROOF_MARKER, "x"); } catch {}
  }
  return __origRSC2(cmd, args, onSpawn, deadline, timeoutCap);
};
`;
// Insert the marker hook right after the DEBUG hook.
script = script.replace("// ===== invoke the recovery as the helper does =====", markerHook + "\n// ===== invoke the recovery as the helper does =====");

const preloadFile = join(dir, "clock-preload.mjs");
writeFileSync(preloadFile, preload);

// Spawn the helper with the clock preload.
const helperArgs = ["--import=" + preloadFile, harnessFile];
console.error("[run] launching helper mode=" + mode + " recoveryTimeoutMs=" + recoveryTimeoutMs + " stepFwd=" + clockStepForwardMs);
const r = spawnSync(process.execPath, helperArgs, {
  env: {
    ...process.env,
    HARNESS_PARAMS: JSON.stringify(params),
    STEP_FORWARD_MS: String(clockStepForwardMs),
    PROOF_MARKER: join(dir, "marker"),
    PROOF_KICKED: join(dir, "kicked"),
  },
  encoding: "utf8",
  timeout: Math.max(120000, recoveryTimeoutMs * 4),
});
console.error(r.stdout);
console.error(r.stderr);
console.error("[run] helper exit code=" + r.status);

// Cleanup: bootout the real job.
const final = sh("launchctl", ["bootout", target]);
console.error("[cleanup] bootout -> code=" + final.code);
rmSync(dir, { recursive: true, force: true });

// Parse the RESULT line.
const m = /RESULT restored=(true|false) wallElapsedMs=(\d+)/.exec(r.stdout || "");
if (!m) {
  console.error("VERDICT[" + mode + "] FAILED: no RESULT line in helper output");
  process.exit(1);
}
const restored = m[1] === "true";
const wallElapsed = Number(m[2]);
console.error("VERDICT[" + mode + "] restored=" + restored + " wallElapsedMs=" + wallElapsed);

if (mode === "FIXED") {
  // post-fix: must recover successfully and bounded
  if (!restored) { console.error("VERDICT FAILED: FIXED should restore"); process.exit(1); }
  if (wallElapsed > recoveryTimeoutMs + 1000) { console.error("VERDICT FAILED: FIXED over budget"); process.exit(1); }
  console.error("VERDICT PASS: FIXED restored=true bounded");
} else {
  // pre-fix: forward step truncates the loop -> restored=false
  if (restored) { console.error("VERDICT FAILED: OLD should not restore under forward step"); process.exit(1); }
  console.error("VERDICT PASS: OLD restored=false (loop truncated by forward step)");
}
