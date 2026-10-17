#!/usr/bin/env bash
set -euo pipefail
VARIANT="${VARIANT:-FIXED}"
echo "=== Variant: $VARIANT ==="

# The PR branch ships the FIXED (performance.now) deadline. For the OLD baseline,
# revert the two-line clock-domain change in-place, and additionally instrument the
# remaining-budget read so the OLD wall-clock deadline observes a wall-clock step
# that lands BETWEEN the deadline seed and the remaining read — exactly the NTP /
# manual-clock divergence this PR fixes. CI runners pin the system clock (NTP), so
# the wall-clock step is injected at that one read site; the launchctl transport
# and the monotonic clock (performance.now / setTimeout) stay REAL.
if [ "$VARIANT" = "OLD" ]; then
  sed -i.bak \
    -e 's/const teardownDeadline = performance\.now() + LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;/const teardownDeadline = Date.now() + LAUNCH_AGENT_BOOTSTRAP_TEARDOWN_TIMEOUT_MS;/' \
    -e 's/const remainingMs = teardownDeadline - performance\.now();/const remainingMs = teardownDeadline - (Date.now() + Number(process.env.WALL_JUMP_MS || 0));/' \
    src/daemon/launchd-runtime.ts
  echo "Reverted to wall-clock deadline (read injects WALL_JUMP_MS):"
  grep -n "teardownDeadline\|remainingMs = " src/daemon/launchd-runtime.ts
fi

UID_NUM="$(id -u)"
export UID_NUM VARIANT

cat > macos-proof.ts <<'SCRIPT'
const VARIANT = process.env.VARIANT || "FIXED";
const UID = process.env.UID_NUM!;
const DIR = process.env.WALL_DIR || "forward";

// Real launchctl transport + real monotonic clock. We only observe settle
// behaviour. For FIXED the deadline is performance.now() (monotonic), immune to
// WALL_JUMP_MS. For OLD the deadline is Date.now() and its remaining-budget read
// is instrumented to add WALL_JUMP_MS, standing in for the wall-clock step a
// clock rollback / forward-jump causes between the deadline seed and the read.
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
  // Forward jump: OLD wall-clock deadline drops remaining to <=0 and fails
  // spuriously ~instantly; FIXED monotonic deadline keeps retrying on the real
  // transport. Observe 2.5s, then exit.
  await new Promise((r) => setTimeout(r, 2500));
  console.log(`VERDICT[${VARIANT}][forward +1e6ms] outcome@2.5s = ${outcome}`);
  process.exit(0);
} else {
  // Backward jump: wait for settle. FIXED honours the monotonic deadline;
  // OLD wall-clock deadline is inflated by the rollback amount (+5s) and settles
  // later.
  while (outcome === "pending") await new Promise((r) => setTimeout(r, 100));
  const elapsed = Math.round(performance.now() - start);
  console.log(`VERDICT[${VARIANT}][backward -5000ms] settled in ${elapsed}ms real`);
  console.log(`  outcome = ${outcome}`);
}
SCRIPT

echo "--- forward wall jump +1,000,000ms ---"
WALL_DIR=forward WALL_JUMP_MS=1000000 node --import tsx/esm ./macos-proof.ts 2>&1 | tail -6

echo "--- backward wall jump -5,000ms (waits for settle, ~340s) ---"
WALL_DIR=backward WALL_JUMP_MS=-5000 node --import tsx/esm ./macos-proof.ts 2>&1 | tail -6

if [ "$VARIANT" = "OLD" ]; then
  rm -f macos-proof.ts
  git checkout -- src/daemon/launchd-runtime.ts
fi
