#!/usr/bin/env bash
# PR #181335 macOS real-behavior proof: managed-server recovery under a wall-clock
# rollback, driven through the SHIPPED entry point `recoverManagedLlamaServer`
# (extensions/llama-cpp/src/managed-server-orphans.ts) which resolves the real
# managed llama-server asset and calls reapOrphanedProcesses.
#
# Real orphaned (launchd-adopted, PPID=1) managed llama-server tree with a
# TERM-resistant descendant; real native process inspection (@openclaw/proc-safe
# darwin binding) and real process.kill. The wall-clock step is injected at the
# OLD variant's remaining-budget read only (CI pins the system clock via NTP); the
# monotonic clock (performance.now / setTimeout) and the transport stay REAL.
set -euo pipefail

VARIANT="${VARIANT:-FIXED}"
WALL_JUMP_MS="${WALL_JUMP_MS:--60000}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$(pwd)}"
LOG="/tmp/orphan-${VARIANT}.log"
# Real managed llama-server installation layout (matches resolveManagedLlamaServerPaths):
#   <STATE_DIR>/tools/llama.cpp/<release>/<platform>-<arch>/<executable>
STATE_DIR="/tmp/llama-state"
LLAMA_RELEASE="b10809"
# Resolve the real platform/arch so findManagedLlamaServerAsset matches exactly.
NODE_PLATFORM="$(node -e 'process.stdout.write(process.platform)')"
NODE_ARCH="$(node -e 'process.stdout.write(process.arch)')"
MANAGED_COMMAND="$STATE_DIR/tools/llama.cpp/$LLAMA_RELEASE/$NODE_PLATFORM-$NODE_ARCH/llama-server"
PORT=19321

cd "$OPENCLAW_DIR"
echo "===== CASE: $VARIANT (wall jump ${WALL_JUMP_MS}ms) =====" | tee "$LOG"
echo "head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"
echo "managed_command=$MANAGED_COMMAND" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# OLD variant: revert orphaned-process.ts to the Date.now() deadline and inject
# the wall-clock step (WALL_JUMP_MS) into the remaining-budget read, standing in
# for the NTP/manual-clock rollback that lands between the deadline seed and the
# read. FIXED leaves performance.now() untouched (monotonic, immune to the step).
# ---------------------------------------------------------------------------
if [ "$VARIANT" = "OLD" ]; then
  cp src/process/orphaned-process.ts "$LOG.postfix.bak"
  python3 - "$LOG.postfix.bak" <<'PY'
import sys
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
# Install a real TERM-resistant managed llama-server simulator (C) at the pinned
# managed path. It ignores SIGTERM (catches, does not exit) and forks a
# TERM-resistant child. findManagedLlamaServerAsset matches this exact path.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$MANAGED_COMMAND")"
cat > /tmp/llama-server.c <<'C'
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
clang -O2 -o "$MANAGED_COMMAND" /tmp/llama-server.c
echo ">>> installed managed llama-server at $MANAGED_COMMAND" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Construct a launchd-adopted orphan: a spawner starts the root, then exits, so
# the root is reparented to PID 1 (PPID=1) -> qualifies as an orphaned managed
# llama-server root for recoverManagedLlamaServer.
# ---------------------------------------------------------------------------
cat > /tmp/spawn-orphan.sh <<SH
#!/bin/bash
# Same cwd as the driver process so recoverManagedLlamaServer's implicit
# cwd (process.cwd()) matches the orphan root's captured cwd.
cd "$OPENCLAW_DIR"
$MANAGED_COMMAND --port $PORT --models-preset /tmp/models.ini --host 127.0.0.1 &
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
# Drive the SHIPPED recoverManagedLlamaServer entry point against the real orphan
# tree. It resolves the managed asset, builds the matchesArguments filter, and
# calls reapOrphanedProcesses. The script is written INSIDE $OPENCLAW_DIR so its
# relative ./extensions import + openclaw/plugin-sdk/* tsconfig paths resolve.
# ---------------------------------------------------------------------------
cat > "$OPENCLAW_DIR/orphan-drive.mts" <<'TS'
import { execSync } from "node:child_process";
import { recoverManagedLlamaServer } from "./extensions/llama-cpp/src/managed-server-orphans.ts";
import { findManagedLlamaServerAsset, resolveManagedLlamaServerPaths } from "./extensions/llama-cpp/src/llama-server-assets.ts";

const VARIANT = process.env.VARIANT || "FIXED";
const WALL_JUMP_MS = Number(process.env.WALL_JUMP_MS || 0);
const ROOT_PID = Number(execSync("cat /tmp/orphan-root.pid").toString().trim());

const port = 19321;
const command = process.env.MANAGED_COMMAND || "/tmp/llama-state/tools/llama.cpp/b10809/darwin-x64/llama-server";
const args = ["--port", String(port), "--models-preset", "/tmp/models.ini", "--host", "127.0.0.1"];

// DIAGNOSTIC: confirm the managed asset resolves against the real platform/arch.
console.log(`[DIAG] platform=${process.platform} arch=${process.arch} state_dir=${process.env.OPENCLAW_STATE_DIR}`);
console.log(`[DIAG] findManagedLlamaServerAsset(command) =>`, findManagedLlamaServerAsset(command)?.name ?? "NOT FOUND");
console.log(`[DIAG] resolveManagedLlamaServerPaths().command =`, resolveManagedLlamaServerPaths().command);
console.log(`[DIAG] command arg =`, command);

// Sanity: confirm the tree is captured as a live orphaned root before recovery.
const before = execSync(`ps -o pid=,ppid=,comm= -p ${ROOT_PID} 2>/dev/null || true`).toString().trim();
console.log(`[${VARIANT}] before recovery: ${before}`);

const t0 = performance.now();
await recoverManagedLlamaServer({ command, port, args });
const t1 = performance.now();
const elapsedMonotonic = Math.round(t1 - t0);

// Did the tree die (SIGKILL escalation) or is it still alive?
let rootAlive = false;
try { rootAlive = (execSync(`ps -o pid= -p ${ROOT_PID} 2>/dev/null || true`).toString().trim() !== ""); } catch { rootAlive = false; }

console.log(`[${VARIANT}] recoverManagedLlamaServer returned elapsed_monotonic=${elapsedMonotonic}ms root_alive_after=${rootAlive}`);
console.log(`VERDICT[${VARIANT}] wall_jump=${WALL_JUMP_MS}ms elapsed_monotonic=${elapsedMonotonic}ms reaped_root=${ROOT_PID} root_alive_after=${rootAlive}`);

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

# macOS has no `timeout`; run with a background deadline guard instead.
OPENCLAW_STATE_DIR="$STATE_DIR" WALL_JUMP_MS="$WALL_JUMP_MS" VARIANT="$VARIANT" MANAGED_COMMAND="$MANAGED_COMMAND" \
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
pkill -9 -f "llama-server" 2>/dev/null || true
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
