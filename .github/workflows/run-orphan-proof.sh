#!/usr/bin/env bash
# PR #181335 macOS real-behavior proof: reapOrphanedProcesses under a wall-clock
# rollback. Real orphaned (launchd-adopted, PPID=1) managed llama-server tree with
# a TERM-resistant descendant; real native process inspection (@openclaw/proc-safe
# darwin binding) and real process.kill. The wall-clock step is injected at the
# OLD variant's remaining-budget read only (CI pins the system clock via NTP); the
# monotonic clock (performance.now / setTimeout) and the transport stay REAL.
set -euo pipefail

VARIANT="${VARIANT:-FIXED}"
WALL_JUMP_MS="${WALL_JUMP_MS:--60000}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$(pwd)}"
LOG="/tmp/orphan-${VARIANT}.log"

cd "$OPENCLAW_DIR"
echo "===== CASE: $VARIANT (wall jump ${WALL_JUMP_MS}ms) =====" | tee "$LOG"
echo "head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# OLD variant: revert orphaned-process.ts to the Date.now() deadline and inject
# the wall-clock step (WALL_JUMP_MS) into the remaining-budget read, standing in
# for the NTP/manual-clock rollback that lands between the deadline seed and the
# read. FIXED leaves performance.now() untouched (monotonic, immune to the step).
# ---------------------------------------------------------------------------
if [ "$VARIANT" = "OLD" ]; then
  cp src/process/orphaned-process.ts "$LOG.postfix.bak"
  python3 - "$LOG.postfix.bak" <<'PY'
import sys,re
src=open(sys.argv[1]).read()
src=src.replace("const deadline = performance.now() + 5_000;","const deadline = Date.now() + 5_000;")
src=src.replace("while (alive().length > 0 && performance.now() < deadline) {",
                "while (alive().length > 0 && (Date.now() + Number(process.env.WALL_JUMP_MS||0)) < deadline) {")
src=src.replace("await sleepWithAbort(Math.min(25, deadline - performance.now()));",
                "await sleepWithAbort(Math.min(25, deadline - (Date.now() + Number(process.env.WALL_JUMP_MS||0))));")
open("src/process/orphaned-process.ts","w").write(src)
print("patched OLD; Date.now sites:",src.count("Date.now()"))
PY
  echo ">>> OLD source patched; waitingForExit uses Date.now()+WALL_JUMP_MS at remaining read" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# Build a real TERM-resistant managed llama-server simulator (C) at a pinned path.
# It ignores SIGTERM (catches, does not exit) and forks a TERM-resistant child.
# ---------------------------------------------------------------------------
mkdir -p /tmp/llama-bin /tmp/llama-state
cat > /tmp/llama-bin/llama-server.c <<'C'
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
static volatile sig_atomic_t term_count = 0;
static void on_term(int sig) {
  term_count++;
  /* TERM-resistant: catch but keep running (forces SIGKILL escalation). */
}
int main(int argc, char **argv) {
  struct sigaction sa; sa.sa_handler = on_term; sigemptyset(&sa.sa_mask); sa.sa_flags = 0;
  sigaction(SIGTERM, &sa, NULL);
  pid_t pid = fork();
  if (pid < 0) return 1;
  if (pid == 0) { /* TERM-resistant child */
    sigaction(SIGTERM, &sa, NULL);
    for (;;) pause();
  }
  for (;;) pause();
  return 0;
}
C
clang -O2 -o /tmp/llama-bin/llama-server /tmp/llama-bin/llama-server.c
echo ">>> built /tmp/llama-bin/llama-server" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Construct a launchd-adopted orphan: a spawner starts the root, then exits, so
# the root is reparented to PID 1 (PPID=1) -> qualifies as an orphaned managed
# llama-server root for reapOrphanedProcesses.
# ---------------------------------------------------------------------------
PORT=19321
cat > /tmp/spawn-orphan.sh <<SH
#!/bin/bash
/tmp/llama-bin/llama-server --port $PORT --models-preset default --host 127.0.0.1 &
echo \$! > /tmp/orphan-root.pid
exit 0
SH
chmod +x /tmp/spawn-orphan.sh
rm -f /tmp/orphan-root.pid
bash /tmp/spawn-orphan.sh
sleep 2

ROOT_PID="$(cat /tmp/orphan-root.pid)"
echo ">>> spawned root pid=$ROOT_PID; waiting for launchd adoption (PPID=1)..." | tee -a "$LOG"
for i in $(seq 1 20); do
  ROOT_PPID="$(ps -o ppid= -p "$ROOT_PID" 2>/dev/null | tr -d ' ' || true)"
  if [ "$ROOT_PPID" = "1" ]; then break; fi
  sleep 1
done
ROOT_PPID="$(ps -o ppid= -p "$ROOT_PID" 2>/dev/null | tr -d ' ' || true)"
echo ">>> root pid=$ROOT_PID ppid=$ROOT_PPID (expected 1 = launchd-adopted)" | tee -a "$LOG"
if [ "$ROOT_PPID" != "1" ]; then
  echo "VERDICT[$VARIANT] FAILED: root was not adopted by launchd (ppid=$ROOT_PPID)" | tee -a "$LOG"
  exit 1
fi

# ---------------------------------------------------------------------------
# Drive the shipped reapOrphanedProcesses owner against the real orphan tree.
# The script is written INSIDE $OPENCLAW_DIR so its relative ./src import resolves.
# ---------------------------------------------------------------------------
cat > "$OPENCLAW_DIR/orphan-drive.mts" <<'TS'
import { execSync } from "node:child_process";

const VARIANT = process.env.VARIANT || "FIXED";
const WALL_JUMP_MS = Number(process.env.WALL_JUMP_MS || 0);
const ROOT_PID = Number(execSync("cat /tmp/orphan-root.pid").toString().trim());

const { reapOrphanedProcesses } = await import("./src/process/orphaned-process.ts");

const port = 19321;
const command = "/tmp/llama-bin/llama-server";
const matchesArguments = (argv: readonly string[]) => {
  const get = (name: string) => {
    for (let i = 0; i < argv.length - 1; i++) if (argv[i] === name) return argv[i + 1];
    return undefined;
  };
  return get("--port") === String(port)
    && get("--models-preset") === "default"
    && get("--host") === "127.0.0.1";
};

// Sanity: confirm the tree is captured as a live orphaned root before reaping.
const before = execSync(`ps -o pid=,ppid=,comm= -p ${ROOT_PID} 2>/dev/null || true`).toString().trim();
console.log(`[${VARIANT}] before reap: ${before}`);

const t0 = performance.now();
const reaped = await reapOrphanedProcesses({ command, matchesArguments });
const t1 = performance.now();
const elapsedMonotonic = Math.round(t1 - t0);

// Did the tree die (SIGKILL escalation) or is it still alive?
let rootAlive = false;
try { rootAlive = (execSync(`ps -o pid= -p ${ROOT_PID} 2>/dev/null || true`).toString().trim() !== ""); } catch { rootAlive = false; }

console.log(`[${VARIANT}] reapOrphanedProcesses returned reaped=[${reaped.join(",")}] elapsed_monotonic=${elapsedMonotonic}ms root_alive_after=${rootAlive}`);
console.log(`VERDICT[${VARIANT}] wall_jump=${WALL_JUMP_MS}ms elapsed_monotonic=${elapsedMonotonic}ms reaped=[${reaped.join(",")}] root_alive_after=${rootAlive}`);

// Distinguish bounded escalation (5s, FIXED) from delayed (5s + |rollback|, OLD).
if (VARIANT === "FIXED") {
  if (elapsedMonotonic < 8000 && !rootAlive) {
    console.log("PROOF PASS: FIXED escalated to SIGKILL in ~5s monotonic under wall-clock rollback");
  } else {
    console.log("PROOF UNEXPECTED: FIXED did not escalate in ~5s");
    process.exitCode = 1;
  }
} else {
  if (elapsedMonotonic >= 55000 && !rootAlive) {
    console.log("PROOF EXPECTED-OLD: OLD delayed SIGKILL by ~|rollback| (bug reproduced on real tree)");
  } else {
    console.log("PROOF UNEXPECTED-OLD: OLD did not delay as expected");
    process.exitCode = 1;
  }
}
TS

# node --import tsx "$OPENCLAW_DIR/orphan-drive.mts" >> "$LOG" 2>&1 || true
# macOS has no `timeout`; run with a background deadline guard instead.
WALL_JUMP_MS="$WALL_JUMP_MS" VARIANT="$VARIANT" \
  node --import tsx "$OPENCLAW_DIR/orphan-drive.mts" >> "$LOG" 2>&1 &
DRIVE_PID=$!
( sleep 150; kill -9 "$DRIVE_PID" 2>/dev/null || true ) &
GUARD_PID=$!
wait "$DRIVE_PID" || true
kill -9 "$GUARD_PID" 2>/dev/null || true
rm -f "$OPENCLAW_DIR/orphan-drive.mts"

# ---------------------------------------------------------------------------
# Cleanup: ensure no leaked llama-server keeps holding state (SIGKILL it).
# ---------------------------------------------------------------------------
pkill -9 -f "/tmp/llama-bin/llama-server" 2>/dev/null || true
if [ "$VARIANT" = "OLD" ]; then
  if [ -f "$LOG.postfix.bak" ]; then
    cp "$LOG.postfix.bak" src/process/orphaned-process.ts
    rm -f "$LOG.postfix.bak"
  fi
fi

echo "" | tee -a "$LOG"
echo "===== END CASE $VARIANT =====" | tee -a "$LOG"
echo "---- full log ----"
cat "$LOG"
