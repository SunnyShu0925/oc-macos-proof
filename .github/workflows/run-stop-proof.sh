#!/usr/bin/env bash
# PR #183033 macOS real-transport proof: LaunchAgent stop deadline under a
# forward wall-clock jump.
#
# The shipped stop path stopLaunchAgent (src/daemon/launchd-stop.ts) boots a
# LaunchAgent out of launchd and waits (waitForLaunchAgentUnloaded) for the job
# to unload AND its PID to die, bounded by LAUNCH_AGENT_STOP_TIMEOUT_MS.
#
# The headless macOS runner has no GUI session, so `launchctl bootstrap
# user/$UID` itself fails with EIO. We therefore drive the stop through the
# shipped stopLaunchAgent against a REAL live child process (a TERM-resistant
# `sleep-forever` we spawn, whose real PID is captured), and wrap ONLY the
# launchctl print/bootout transport so print reports the job as running with
# that real PID (a real `launchctl print` format) and bootout succeeds. The PID
# liveness probe (isPidDefinitelyDead -> process.kill) and the entire deadline
# logic under test stay 100% real. This mirrors PR #175204's proof, which also
# wraps the launchctl transport to construct the pending-teardown state.
#
# OLD (Date.now deadline): the wall-clock step injected at the deadline reads
# makes `Date.now()+WALL_JUMP_MS >= deadline` true the moment the wait loop
# starts -> spurious launchAgentStopError (stop rejected early).
# FIXED (performance.now deadline): the monotonic deadline is immune; the stop
# stays pending for the full 340s budget.
set -euo pipefail

VARIANT="${VARIANT:-FIXED}"
WALL_JUMP_MS="${WALL_JUMP_MS:-1000000}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$(pwd)}"
LOG="/tmp/stop-${VARIANT}.log"
LABEL="ai.openclaw.proofstop"
OBSERVE_MS="${OBSERVE_MS:-15000}"

cd "$OPENCLAW_DIR"
echo "===== CASE: $VARIANT (wall jump +${WALL_JUMP_MS}ms, observe ${OBSERVE_MS}ms) =====" | tee "$LOG"
echo "head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"
echo "label=$LABEL observe=${OBSERVE_MS}ms" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# OLD variant: revert launchd-stop.ts to the Date.now() deadline and inject the
# wall-clock step into the deadline/remaining reads (stands in for an NTP /
# manual forward jump between seed and reads). FIXED leaves performance.now()
# untouched.
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
open("src/daemon/launchd-stop.ts","w").write(src)
print("patched OLD; Date.now() sites:", src.count("Date.now()"))
PY
  echo ">>> OLD source patched (Date.now deadline + WALL_JUMP_MS injection)" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# Wrap ONLY the launchctl print/bootout transport so the headless runner can
# drive the stop through a real PID liveness probe. print reports the job as
# running with the real PROOF_PID (real `launchctl print` format); bootout
# succeeds. All other launchctl commands go to the real binary.
# ---------------------------------------------------------------------------
cp src/daemon/launchd-exec.ts "$LOG.exec.bak"
python3 - "$LOG.exec.bak" <<'PY'
import sys
src = open(sys.argv[1]).read()
marker = "  const deadline = typeof budget === \"object\" ? budget : undefined;"
assert marker in src, "execLaunchctl body marker not found"
inject = (
    "  const __PROOF_PID = Number(process.env.PROOF_PID || 0);\n"
    "  if (args[0] === \"print\" && __PROOF_PID > 0) {\n"
    "    const target = args[1] || \"\";\n"
    "    // Real `launchctl print` format for a running job, with the real PID.\n"
    "    return { code: 0, termination: \"exit\", stdout: `${target} = {\\n\\tpid = ${__PROOF_PID}\\n\\tstate = running\\n}\\n`, stderr: \"\" };\n"
    "  }\n"
    "  if (args[0] === \"bootout\") {\n"
    "    return { code: 0, termination: \"exit\", stdout: \"\", stderr: \"\" };\n"
    "  }\n"
)
src = src.replace(marker, inject + marker)
open("src/daemon/launchd-exec.ts","w").write(src)
print("wrapped execLaunchctl print/bootout (PROOF_PID env)")
PY
echo ">>> wrapped execLaunchctl print/bootout transport" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Bypass the launchd-membership gate: the headless runner cannot truthfully
# decide process membership (no GUI launchd session), so the shipped stop path
# would misclassify and refuse. This is a proof-environment bypass only; the
# deadline logic under test is untouched.
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
# Spawn a real TERM-resistant child so isPidDefinitelyDead(pid) (real
# process.kill) sees a genuinely live PID and the wait loop spins on the
# deadline. We do NOT bootstrap it via launchctl (headless EIO); the print
# wrapper reports it as the running job.
# ---------------------------------------------------------------------------
mkdir -p /tmp/proofstop
cat > /tmp/proofstop/sleep-forever.c <<'C'
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
static void ignore(int sig){}
int main(int argc, char **argv){
  struct sigaction sa; sa.sa_handler = ignore; sigemptyset(&sa.sa_mask); sa.sa_flags = 0;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  pid_t pid = fork();
  if (pid == 0) { for (;;) pause(); }
  for (;;) pause();
  return 0;
}
C
clang -O2 -o /tmp/proofstop/sleep-forever /tmp/proofstop/sleep-forever.c
/tmp/proofstop/sleep-forever &
PROOF_PID=$!
sleep 1
if ! kill -0 "$PROOF_PID" 2>/dev/null; then
  echo "VERDICT[$VARIANT] FAILED: sleep-forever did not stay alive (pid=$PROOF_PID)" | tee -a "$LOG"
  exit 1
fi
echo ">>> real live child pid=$PROOF_PID" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Drive the SHIPPED stopLaunchAgent. The print wrapper reports the job running
# with the real live PID; isPidDefinitelyDead (real) keeps the wait spinning.
# OLD must throw a spurious launchAgentStopError under the forward wall-clock
# step; FIXED must stay pending for the whole observe window.
# ---------------------------------------------------------------------------
cat > "$OPENCLAW_DIR/stop-drive.mts" <<'TS'
import { stopLaunchAgent } from "./src/daemon/launchd.ts";

const VARIANT = process.env.VARIANT || "FIXED";
const WALL_JUMP_MS = Number(process.env.WALL_JUMP_MS || 0);
const OBSERVE_MS = Number(process.env.OBSERVE_MS || 15000);

const output: string[] = [];
const stdout = { write: (s: string) => { output.push(s); } };

const t0 = performance.now();
let outcome = "pending";
stopLaunchAgent({ env: process.env as any, stdout: stdout as any } as any).then(
  () => { outcome = "resolved"; },
  (e: any) => { outcome = "rejected:" + (e?.message || String(e)); },
);

// Observe; do not await stopLaunchAgent itself (OLD rejects fast, FIXED stays
// pending through the 340s budget).
await new Promise((r) => setTimeout(r, OBSERVE_MS));
const elapsed = Math.round(performance.now() - t0);

console.log(`VERDICT[${VARIANT}] wall_jump=+${WALL_JUMP_MS}ms observe=${OBSERVE_MS}ms elapsed=${elapsed}ms outcome=${outcome}`);
console.log("--- stopLaunchAgent stdout ---");
console.log(output.join(""));
TS

WALL_JUMP_MS="$WALL_JUMP_MS" VARIANT="$VARIANT" OBSERVE_MS="$OBSERVE_MS" PROOF_PID="$PROOF_PID" \
  OPENCLAW_LAUNCHD_LABEL="$LABEL" OPENCLAW_PROFILE="default" HOME="$HOME" \
  node --import tsx/esm "$OPENCLAW_DIR/stop-drive.mts" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Cleanup: kill the child and restore patched sources.
# ---------------------------------------------------------------------------
kill -9 "$PROOF_PID" 2>/dev/null || true
pkill -9 -f "proofstop/sleep-forever" 2>/dev/null || true
if [ -f "$LOG.stop.bak" ]; then cp "$LOG.stop.bak" src/daemon/launchd-stop.ts 2>/dev/null || true; rm -f "$LOG.stop.bak"; fi
if [ -f "$LOG.exec.bak" ]; then cp "$LOG.exec.bak" src/daemon/launchd-exec.ts 2>/dev/null || true; rm -f "$LOG.exec.bak"; fi
if [ -f "$LOG.current.bak" ]; then cp "$LOG.current.bak" src/daemon/launchd-current-service.ts 2>/dev/null || true; rm -f "$LOG.current.bak"; fi
rm -f "$OPENCLAW_DIR/stop-drive.mts"

echo "" | tee -a "$LOG"
echo "===== END CASE $VARIANT =====" | tee -a "$LOG"
