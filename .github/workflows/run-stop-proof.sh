#!/usr/bin/env bash
# PR #183033 macOS real-transport proof: LaunchAgent stop deadline under a
# forward wall-clock jump.
#
# The shipped stop path stopLaunchAgent (src/daemon/launchd-stop.ts) boots a real
# LaunchAgent out of launchd and then waits (waitForLaunchAgentUnloaded) for the
# job to unload AND its PID to die, bounded by LAUNCH_AGENT_STOP_TIMEOUT_MS.
# A TERM-resistant child keeps the PID alive after bootout, so the wait actually
# spins on the deadline instead of completing immediately.
#
# OLD (Date.now deadline): the wall-clock step injected at the deadline reads
# makes `Date.now()+WALL_JUMP_MS >= deadline` true the moment the wait loop
# starts -> spurious launchAgentStopError (stop rejected early).
# FIXED (performance.now deadline): the monotonic deadline is immune to the
# wall-clock step; the stop stays pending for the full 340s budget.
#
# Real launchctl (user domain), real PID liveness (process.kill), real monotonic
# clock throughout. Only the deadline clock-domain is reverted for OLD, and the
# gui-domain resolver is pinned to the user domain so the headless macOS runner
# can drive the real launchctl transport.
set -euo pipefail

VARIANT="${VARIANT:-FIXED}"
WALL_JUMP_MS="${WALL_JUMP_MS:-1000000}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$(pwd)}"
LOG="/tmp/stop-${VARIANT}.log"
LABEL="ai.openclaw.proofstop"
DOMAIN="user/$(id -u)"
SERVICE_TARGET="$DOMAIN/$LABEL"
OBSERVE_MS="${OBSERVE_MS:-15000}"

cd "$OPENCLAW_DIR"
echo "===== CASE: $VARIANT (wall jump +${WALL_JUMP_MS}ms, observe ${OBSERVE_MS}ms) =====" | tee "$LOG"
echo "head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"
echo "label=$LABEL domain=$DOMAIN service_target=$SERVICE_TARGET" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# OLD variant: revert launchd-stop.ts to the Date.now() deadline and inject the
# wall-clock step (WALL_JUMP_MS) into the deadline/remaining reads, standing in
# for the NTP/manual-clock forward jump that lands between the deadline seed and
# the reads. FIXED leaves performance.now() untouched (monotonic, immune).
# ---------------------------------------------------------------------------
if [ "$VARIANT" = "OLD" ]; then
  cp src/daemon/launchd-stop.ts "$LOG.postfix.bak"
  python3 - "$LOG.postfix.bak" <<'PY'
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
print("patched OLD; Date.now() sites in waitForLaunchAgentUnloaded:", src.count("Date.now()"))
PY
  echo ">>> OLD source patched (Date.now deadline + WALL_JUMP_MS injection)" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# Pin the gui-domain resolver to the user domain (proof environment: headless
# macOS runner has no GUI login session, so launchctl must use user/$UID). This
# only changes which real launchctl domain the shipped stop path talks to; the
# deadline logic under test is untouched. Both variants get this pin.
# ---------------------------------------------------------------------------
cp src/daemon/launchd-runtime.ts "$LOG.runtime.bak"
python3 - "$LOG.runtime.bak" <<'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace(
    "return `gui/${process.getuid()}`;",
    "return `user/${process.getuid()}`; /* PR#183033 proof: headless runner has no GUI session */")
open("src/daemon/launchd-runtime.ts","w").write(src)
print("pinned resolveLaunchAgentGuiDomain -> user domain")
PY
echo ">>> gui-domain resolver pinned to user/$UID" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# TERM-resistant child: bootout sends SIGTERM; the child ignores it and keeps a
# live PID so waitForLaunchAgentUnloaded's isPidDefinitelyDead(pid) stays false
# and the wait loop really spins on the deadline.
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
echo ">>> built TERM-resistant /tmp/proofstop/sleep-forever" | tee -a "$LOG"

cat > /tmp/proofstop/plist.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/tmp/proofstop/sleep-forever</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF

# Fresh bootstrap: bootout any stale job, then bootstrap + enable + capture PID.
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" /tmp/proofstop/plist.plist || { echo "VERDICT[$VARIANT] FAILED: launchctl bootstrap" | tee -a "$LOG"; exit 1; }
launchctl enable "$SERVICE_TARGET" 2>/dev/null || true
sleep 1
PID="$(launchctl print "$SERVICE_TARGET" 2>/dev/null | awk '/pid =/{print $3; exit}' | tr -d ' ' || true)"
echo ">>> installed $LABEL pid=$PID" | tee -a "$LOG"
if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
  echo "VERDICT[$VARIANT] FAILED: no live PID for $LABEL" | tee -a "$LOG"
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
  exit 1
fi

# ---------------------------------------------------------------------------
# Drive the SHIPPED stopLaunchAgent against the real LaunchAgent. Bootout is a
# real `launchctl bootout user/$UID/label`; the TERM-resistant child keeps the
# PID alive, so waitForLaunchAgentUnloaded spins on the deadline. OLD must throw
# a spurious launchAgentStopError under the forward wall-clock step; FIXED must
# stay pending for the whole observe window.
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

// Observe for the window; do not await stopLaunchAgent itself (OLD rejects fast,
// FIXED stays pending through the 340s budget).
await new Promise((r) => setTimeout(r, OBSERVE_MS));
const elapsed = Math.round(performance.now() - t0);

console.log(`VERDICT[${VARIANT}] wall_jump=+${WALL_JUMP_MS}ms observe=${OBSERVE_MS}ms elapsed=${elapsed}ms outcome=${outcome}`);
console.log("--- stopLaunchAgent stdout ---");
console.log(output.join(""));
TS

WALL_JUMP_MS="$WALL_JUMP_MS" VARIANT="$VARIANT" OBSERVE_MS="$OBSERVE_MS" \
  OPENCLAW_LAUNCHD_LABEL="$LABEL" OPENCLAW_PROFILE="default" HOME="$HOME" \
  node --import tsx/esm "$OPENCLAW_DIR/stop-drive.mts" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Cleanup: bootout the proof job and restore patched sources.
# ---------------------------------------------------------------------------
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
pkill -9 -f "proofstop/sleep-forever" 2>/dev/null || true
if [ "$VARIANT" = "OLD" ]; then
  if [ -f "$LOG.postfix.bak" ]; then
    cp "$LOG.postfix.bak" src/daemon/launchd-stop.ts
    rm -f "$LOG.postfix.bak"
  fi
fi
if [ -f "$LOG.runtime.bak" ]; then
  cp "$LOG.runtime.bak" src/daemon/launchd-runtime.ts
  rm -f "$LOG.runtime.bak"
fi
rm -f "$OPENCLAW_DIR/stop-drive.mts"

echo "" | tee -a "$LOG"
echo "===== END CASE $VARIANT =====" | tee -a "$LOG"
