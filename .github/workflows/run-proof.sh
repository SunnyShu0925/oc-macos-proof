#!/usr/bin/env bash
set -euo pipefail
VARIANT="${VARIANT:-FIXED}"
echo "=== Variant: $VARIANT ==="

if [ "$VARIANT" = "OLD" ]; then
  sed -i.bak \
    -e 's/const teardownDeadline = performance\.now() + LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;/const teardownDeadline = Date.now() + LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;/' \
    -e 's/const remainingMs = teardownDeadline - performance\.now();/const remainingMs = teardownDeadline - Date.now();/' \
    src/daemon/launchd-runtime.ts
  echo "Reverted to Date.now deadline:"
  grep -n "teardownDeadline\|remainingMs = " src/daemon/launchd-runtime.ts
fi

UID_NUM="$(id -u)"
export UID_NUM VARIANT

# --- DBG pass (FIXED, real transport, no wall jump): why does it throw? ---
if [ "$VARIANT" = "FIXED" ] && [ -n "${RUN_DBG:-}" ]; then
  python3 - <<'PY2'
p="src/daemon/launchd-runtime.ts"
s=open(p).read()
needle="    const remainingMs = teardownDeadline - performance.now();"
assert needle in s, "needle not found"
inject="    const remainingMs = teardownDeadline - performance.now();\n" + \
  "    console.error('[DBG] remainingMs=' + remainingMs + ' retryPending=' + params.retryPendingTeardown +\n" + \
  "      ' pendingTeardown=' + isLaunchctlBootstrapPendingTeardown(boot) +\n" + \
  "      ' term=' + boot.termination + ' code=' + boot.code +\n" + \
  "      ' stderr=' + JSON.stringify(boot.stderr));"
s=s.replace(needle, inject)
open(p,"w").write(s)
print("instrumented")
PY2
  cat > ./dbg.ts <<'SCRIPT'
  const UID = process.env.UID_NUM!;
  const { bootstrapLaunchAgentOrThrow } = await import("./src/daemon/launchd-runtime.ts");
  try {
    await bootstrapLaunchAgentOrThrow({
      domain: "user/" + UID,
      serviceTarget: "user/" + UID + "/ai.openclaw.probe",
      plistPath: "/tmp/probe.plist",
      actionHint: "dbg", retryPendingTeardown: true,
    });
    console.log("RESULT resolved");
  } catch (e:any) { console.log("RESULT threw:", e.message); }
SCRIPT
  UID_NUM=$UID_NUM node --import tsx/esm ./dbg.ts 2>&1 | grep -E "\[DBG\]|RESULT" | head -12
  rm -f dbg.ts
  git checkout -- src/daemon/launchd-runtime.ts
fi

cat > macos-proof.ts <<'SCRIPT'
const VARIANT = process.env.VARIANT || "FIXED";
const UID = process.env.UID_NUM!;
const DIR = process.env.WALL_DIR || "forward";
const WALL_JUMP_MS = Number(process.env.WALL_JUMP_MS || 1_000_000);

// Real launchctl transport + real monotonic clock (performance.now / setTimeout).
// CI runners pin the system clock (NTP), so the wall-clock step is injected
// in-process: the FIRST Date.now() call (deadline seed) returns real time, all
// later calls (remaining-budget read) return real+JUMP. This is the real
// NTP/manual-clock divergence a wall-clock deadline cannot survive.
const realNow = Date.now.bind(Date);
let calls = 0;
Date.now = () => {
  calls += 1;
  return realNow() + (calls > 1 ? WALL_JUMP_MS : 0);
};

// NOTE: we deliberately do NOT replace execLaunchctl. The transport stays the
// real `launchctl` child process. We only observe the *settle behaviour* of the
// production retry loop under a wall-clock jump.
const { bootstrapLaunchAgentOrThrow } = await import("./src/daemon/launchd-runtime.ts");
let outcome = "pending";
const start = performance.now();
bootstrapLaunchAgentOrThrow({
  domain: "user/" + UID,
  serviceTarget: "user/" + UID + "/ai.openclaw.probe",
  plistPath: "/tmp/probe.plist",
  actionHint: "macos-real-transport-proof",
  retryPendingTeardown: true,
}).then(
  () => { outcome = "resolved"; },
  (e: any) => { outcome = "rejected:" + (e.message || e); },
);

if (DIR === "forward") {
  // Forward jump: a wall-clock deadline drops remaining budget to <=0 and fails
  // spuriously ~instantly; the monotonic deadline keeps retrying on the real
  // transport. Observe 2.5s, then exit.
  await new Promise((r) => setTimeout(r, 2500));
  console.log(`VERDICT[${VARIANT}][forward +1e6ms] outcome@2.5s = ${outcome}`);
  process.exit(0);
} else {
  // Backward jump: wait for the loop to settle at the monotonic deadline (~70s).
  // The wall-clock variant inflates the budget by the rollback amount (+5s).
  while (outcome === "pending") await new Promise((r) => setTimeout(r, 100));
  const elapsed = Math.round(performance.now() - start);
  console.log(`VERDICT[${VARIANT}][backward -5000ms] settled in ${elapsed}ms real`);
  console.log(`  outcome = ${outcome}`);
}
SCRIPT

echo "--- forward wall jump +1,000,000ms ---"
DIR=forward WALL_JUMP_MS=1000000 node --import tsx/esm ./macos-proof.ts 2>&1 | tail -8

echo "--- backward wall jump -5,000ms (waits for settle, ~70-75s) ---"
DIR=backward WALL_JUMP_MS=-5000 node --import tsx/esm ./macos-proof.ts 2>&1 | tail -8

if [ "$VARIANT" = "OLD" ]; then
  rm -f macos-proof.ts
  git checkout -- src/daemon/launchd-runtime.ts 2>/dev/null || true
fi
