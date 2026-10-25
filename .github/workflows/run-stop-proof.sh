#!/usr/bin/env bash
# PR #183033 macOS real-transport stop-deadline proof — v2.
#
# Drives the SHIPPED stopLaunchAgent (src/daemon/launchd-stop.ts) under a
# forward wall-clock jump, and shows the stop running to a BOUNDED EXPIRY (or
# port-release wait), not a 15s pending timeout.
#
# Headless macOS runners have no GUI launchd session: `launchctl bootstrap
# user/$UID` fails with EIO, so a real bootstrapped job (with a live PID)
# cannot be constructed. We therefore wrap ONLY the launchctl print/bootout
# transport so the shipped stop path drives against a REAL live child PID, and
# bypass the launchd-membership gate (proof-environment only). The deadline
# logic under test is 100% shipped and untouched.
#
# To make the bounded expiry observable in a fast workflow, the stop budget
# constants in gateway-shutdown-budget.mjs are shortened (drain 315s -> 8s),
# so LAUNCH_AGENT_STOP_TIMEOUT_MS ~= 33s and the port-release budget ~= 23s.
# This is a proof-environment observability injection; the monotonic-vs-wall
# deadline logic itself is unmodified.
#
# Scenarios (SCENARIO env):
#   unload — print reports the job running with a REAL live PID; the stop spins
#            on PID liveness and hits its bounded expiry. FIXED honours the full
#            ~33s budget; OLD (Date.now deadline) rejects prematurely under the
#            forward wall-clock step.
#   port   — unload completes (print reports not-loaded, PID dead), then a real
#            TCP port is kept busy; waitForGatewayPortRelease spins to its
#            bounded expiry. FIXED honours the full budget; OLD rejects early.
#
# OLD (Date.now deadline) injects the wall-clock step at the deadline/remaining
# reads (stands in for an NTP / manual forward jump between seed and reads).
set -euo pipefail

VARIANT="${VARIANT:-FIXED}"
SCENARIO="${SCENARIO:-unload}"
WALL_JUMP_MS="${WALL_JUMP_MS:-1000000}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$(pwd)}"
LOG="/tmp/stop-${VARIANT}-${SCENARIO}.log"
LABEL="ai.openclaw.proofstop"
OBSERVE_MS="${OBSERVE_MS:-40000}"

cd "$OPENCLAW_DIR"
echo "===== CASE: $VARIANT / $SCENARIO (wall jump +${WALL_JUMP_MS}ms, observe ${OBSERVE_MS}ms) =====" | tee "$LOG"
echo "head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"
echo "label=$LABEL scenario=$SCENARIO observe=${OBSERVE_MS}ms" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# OLD variant: revert launchd-stop.ts to the Date.now() deadline and inject the
# wall-clock step into the deadline/remaining reads. FIXED leaves
# performance.now() untouched.
# ---------------------------------------------------------------------------
if [ "$VARIANT" = "OLD" ]; then
  cp src/daemon/launchd-stop.ts "$LOG.stop.bak"
  python3 - "$LOG.stop.bak" <<'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace(
    "const deadline = performance.now() + LAUNCH_AGENT_STOP_TIMEOUT_MS;",
    "const deadline = Date.now() + LAUNCH_AGENT_STOP_TIMEOUT_MS;")
src = src.replace(
    "if (performance.now() >= deadline) {",
    "if ((Date.now() + Number(process.env.WALL_JUMP_MS||0)) >= deadline) {")
src = src.replace(
    "await sleep(Math.min(100, Math.max(0, deadline - performance.now())));",
    "await sleep(Math.min(100, Math.max(0, deadline - (Date.now() + Number(process.env.WALL_JUMP_MS||0)))));")
src = src.replace(
    "const deadline = performance.now() + LAUNCH_AGENT_STOP_PORT_RELEASE_TIMEOUT_MS;",
    "const deadline = Date.now() + LAUNCH_AGENT_STOP_PORT_RELEASE_TIMEOUT_MS;")
src = src.replace(
    "while (performance.now() < deadline) {",
    "while ((Date.now() + Number(process.env.WALL_JUMP_MS||0)) < deadline) {")
src = src.replace(
    "await sleep(Math.min(LAUNCH_AGENT_STOP_PORT_RELEASE_POLL_MS, deadline - performance.now()));",
    "await sleep(Math.min(LAUNCH_AGENT_STOP_PORT_RELEASE_POLL_MS, deadline - (Date.now() + Number(process.env.WALL_JUMP_MS||0))));")
open("src/daemon/launchd-stop.ts","w").write(src)
print("patched OLD; Date.now() sites:", src.count("Date.now()"))
PY
  echo ">>> OLD source patched (Date.now deadline + WALL_JUMP_MS injection)" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# Shorten the stop budget so bounded expiry is observable in a fast workflow.
# drain 315s -> 8s => STOP_TIMEOUT_MS=23s, LAUNCH_AGENT_STOP_TIMEOUT_MS~=33s,
# port-release budget ~=23s. Proof-environment observability injection only.
# ---------------------------------------------------------------------------
cp gateway-shutdown-budget.mjs "$LOG.budget.bak"
python3 - "$LOG.budget.bak" <<'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace(
    "const GATEWAY_SHUTDOWN_DRAIN_TIMEOUT_MS = 315_000;",
    "const GATEWAY_SHUTDOWN_DRAIN_TIMEOUT_MS = 8_000;")
open("gateway-shutdown-budget.mjs","w").write(src)
print("shortened GATEWAY_SHUTDOWN_DRAIN_TIMEOUT_MS -> 8000")
PY
echo ">>> shortened stop budget (drain 315s -> 8s)" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Wrap ONLY the launchctl print/bootout transport. print reports the job as
# running (with real PROOF_PID) for unload, or not-loaded for port; bootout
# succeeds. All other launchctl commands go to the real binary.
# ---------------------------------------------------------------------------
cp src/daemon/launchd-exec.ts "$LOG.exec.bak"
python3 - "$LOG.exec.bak" <<'PY'
import sys, os
src = open(sys.argv[1]).read()
marker = "  const deadline = typeof budget === \"object\" ? budget : undefined;"
assert marker in src, "execLaunchctl body marker not found"
inject = (
    "  const __PROOF_PID = Number(process.env.PROOF_PID || 0);\n"
    "  const __PROOF_STATE = process.env.PROOF_PRINT_STATE || \"running\";\n"
    "  if (args[0] === \"print\" && __PROOF_PID > 0) {\n"
    "    const target = args[1] || \"\";\n"
    "    if (__PROOF_STATE !== \"running\") {\n"
    "      // Real `launchctl print` output for an absent job (not-loaded).\n"
    "      return { code: 1, termination: \"exit\", stdout: \"\", stderr: \"Could not find service \\\"\" + target + \"\\\" in domain for user\" };\n"
    "    }\n"
    "    // Real `launchctl print` format for a running job, with the real PID.\n"
    "    return { code: 0, termination: \"exit\", stdout: `${target} = {\\n\\tpid = ${__PROOF_PID}\\n\\tstate = running\\n}\\n`, stderr: \"\" };\n"
    "  }\n"
    "  if (args[0] === \"bootout\") {\n"
    "    return { code: 0, termination: \"exit\", stdout: \"\", stderr: \"\" };\n"
    "  }\n"
)
src = src.replace(marker, inject + marker)
open("src/daemon/launchd-exec.ts","w").write(src)
print("wrapped execLaunchctl print/bootout (PROOF_PID/PROOF_PRINT_STATE env)")
PY
echo ">>> wrapped execLaunchctl print/bootout transport" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Bypass the launchd-membership gate (headless runner cannot truthfully decide
# process membership). Proof-environment bypass only.
# ---------------------------------------------------------------------------
cp src/daemon/launchd-current-service.ts "$LOG.current.bak"
python3 - "$LOG.current.bak" <<'PY'
import sys
src = open(sys.argv[1]).read()
marker = "export async function isCurrentProcessInsideLaunchdService(label: string): Promise<boolean> {\n"
assert marker in src, "isCurrentProcessInsideLaunchdService body marker not found"
inject = (
    "export async function isCurrentProcessInsideLaunchdService(label: string): Promise<boolean> {\n"
    "  // PR#183033 proof: headless macOS runner has no GUI launchd session, so\n"
    "  // launchd membership cannot be truthfully decided here. Bypass the gate;\n"
    "  // the stop-deadline logic under test is untouched. The remainder of the\n"
    "  // original body is unreachable but syntactically valid.\n"
    "  return false;\n"
)
src = src.replace(marker, inject)
open("src/daemon/launchd-current-service.ts","w").write(src)
print("bypassed isCurrentProcessInsideLaunchdService -> false")
PY
echo ">>> bypassed launchd-membership gate (proof env only)" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Real live child: isPidDefinitelyDead(pid) (real process.kill) sees a
# genuinely live PID so the unload wait can spin on the deadline.
# ---------------------------------------------------------------------------
mkdir -p /tmp/proofstop
cat > /tmp/proofstop/sleep-forever.c <<'C'
#include <signal.h>
#include <unistd.h>
static void ignore(int sig){}
int main(void){
  struct sigaction sa; sa.sa_handler = ignore; sigemptyset(&sa.sa_mask); sa.sa_flags = 0;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  for (;;) pause();
  return 0;
}
C
clang -O2 -o /tmp/proofstop/sleep-forever /tmp/proofstop/sleep-forever.c
/tmp/proofstop/sleep-forever &
PROOF_PID=$!
sleep 1
if ! kill -0 "$PROOF_PID" 2>/dev/null; then
  echo "VERDICT[$VARIANT/$SCENARIO] FAILED: sleep-forever did not stay alive (pid=$PROOF_PID)" | tee -a "$LOG"
  exit 1
fi
echo ">>> real live child pid=$PROOF_PID" | tee -a "$LOG"

# Print state for unload keeps the PID "running" so the stop spins on liveness;
# for port it reports not-loaded so unload completes and control reaches the
# port-release wait.
PRINT_STATE="running"
if [ "$SCENARIO" = "port" ]; then
  PRINT_STATE="not-loaded"
fi

# ---------------------------------------------------------------------------
# Port scenario: bind a REAL TCP listener on an ephemeral port and keep it busy
# so probePortUsage (real) reports "busy" and waitForGatewayPortRelease spins
# to its bounded expiry.
# ---------------------------------------------------------------------------
PROOF_PORT=0
PORT_PID=""
if [ "$SCENARIO" = "port" ]; then
  node -e '
    const net = require("net");
    const s = net.createServer(() => {});
    s.listen(0, "127.0.0.1", () => {
      console.log("BUSY_PORT=" + s.address().port);
      process.on("SIGTERM", () => process.exit(0));
    });
    setInterval(() => {}, 1000);
  ' > /tmp/busy-port.txt &
  PORT_PID=$!
  sleep 1
  # macOS (BSD) grep has no -P; extract the port with sed.
  PROOF_PORT=$(sed -n 's/.*BUSY_PORT=\([0-9][0-9]*\).*/\1/p' /tmp/busy-port.txt | head -1)
  echo ">>> real busy port=$PROOF_PORT (listener pid=$PORT_PID)" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# Drive the SHIPPED stopLaunchAgent and record when it settles (bounded expiry
# or premature rejection), not just whether it stays pending.
# ---------------------------------------------------------------------------
cat > "$OPENCLAW_DIR/stop-drive.mts" <<'TS'
import { stopLaunchAgent } from "./src/daemon/launchd.ts";

const VARIANT = process.env.VARIANT || "FIXED";
const SCENARIO = process.env.SCENARIO || "unload";
const OBSERVE_MS = Number(process.env.OBSERVE_MS || 40000);

const output: string[] = [];
const stdout = { write: (s: string) => { output.push(s); } };

const t0 = performance.now();
let verdict = "pending";
let settledAt = -1;
stopLaunchAgent({ env: process.env as any, stdout: stdout as any } as any).then(
  () => { verdict = "resolved"; settledAt = Math.round(performance.now() - t0); },
  (e: any) => { verdict = "rejected:" + (e?.message || String(e)); settledAt = Math.round(performance.now() - t0); },
);

await new Promise((r) => setTimeout(r, OBSERVE_MS));
if (verdict === "pending") settledAt = Math.round(performance.now() - t0);

console.log(`VERDICT[${VARIANT}/${SCENARIO}] wall_jump=+${process.env.WALL_JUMP_MS || 0}ms observe=${OBSERVE_MS}ms settled_at=${settledAt}ms verdict=${verdict}`);
console.log("--- stopLaunchAgent stdout ---");
console.log(output.join(""));

process.exit(0);
TS

WALL_JUMP_MS="$WALL_JUMP_MS" VARIANT="$VARIANT" SCENARIO="$SCENARIO" OBSERVE_MS="$OBSERVE_MS" \
  PROOF_PID="$PROOF_PID" PROOF_PRINT_STATE="$PRINT_STATE" \
  OPENCLAW_LAUNCHD_LABEL="$LABEL" OPENCLAW_SERVICE_KIND="gateway" \
  OPENCLAW_SERVICE_MARKER="openclaw" OPENCLAW_GATEWAY_PORT="$PROOF_PORT" \
  OPENCLAW_PROFILE="default" HOME="$HOME" \
  node --import tsx/esm "$OPENCLAW_DIR/stop-drive.mts" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Cleanup: kill the child + listener and restore patched sources.
# ---------------------------------------------------------------------------
kill -9 "$PROOF_PID" 2>/dev/null || true
[ -n "$PORT_PID" ] && kill -9 "$PORT_PID" 2>/dev/null || true
pkill -9 -f "proofstop/sleep-forever" 2>/dev/null || true
if [ -f "$LOG.stop.bak" ]; then cp "$LOG.stop.bak" src/daemon/launchd-stop.ts 2>/dev/null || true; rm -f "$LOG.stop.bak"; fi
if [ -f "$LOG.exec.bak" ]; then cp "$LOG.exec.bak" src/daemon/launchd-exec.ts 2>/dev/null || true; rm -f "$LOG.exec.bak"; fi
if [ -f "$LOG.current.bak" ]; then cp "$LOG.current.bak" src/daemon/launchd-current-service.ts 2>/dev/null || true; rm -f "$LOG.current.bak"; fi
if [ -f "$LOG.budget.bak" ]; then cp "$LOG.budget.bak" gateway-shutdown-budget.mjs 2>/dev/null || true; rm -f "$LOG.budget.bak"; fi
rm -f "$OPENCLAW_DIR/stop-drive.mts" /tmp/busy-port.txt

echo "" | tee -a "$LOG"
echo "===== END CASE $VARIANT / $SCENARIO =====" | tee -a "$LOG"
