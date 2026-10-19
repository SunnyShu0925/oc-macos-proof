#!/usr/bin/env bash
# PR #175204 diamond proof v2: shipped `openclaw daemon install` CLI entry.
# Exercises bootstrapLaunchAgentOrThrow through the shipped CLI command
# (node --import tsx src/entry.ts daemon install) instead of importing the
# function directly, so the proof path is the shipped entry point.
#
# The ESM loader (proof-loader.mjs):
#   - forces execLaunchctl("bootstrap",...) to return a real EIO that
#     isLaunchctlBootstrapPendingTeardown classifies as pending teardown
#     (reproduces a bootout racing the next bootstrap); other launchctl
#     commands run through the real launchctl binary on the macOS runner
#   - VARIANT=OLD: patches performance.now() -> Date.now()+WALL_JUMP_MS so
#     the wall-clock deadline observes a step; VARIANT=FIXED: untouched
set -euo pipefail

VARIANT="${VARIANT:-FIXED}"
WALL_DIR="${WALL_DIR:-forward}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$(pwd)}"
LOADER="${LOADER_PATH:-/home/code/github/contributions/pr-175204-evidence/proof-loader.mjs}"

if [ "$WALL_DIR" = "forward" ]; then
  WALL_JUMP_MS=1000000
  BUDGET_MS=2500
else
  WALL_JUMP_MS=-5000
  BUDGET_MS=360000
fi

echo "=== PR #175204 diamond proof v2: shipped openclaw daemon install entry ==="
echo "variant=$VARIANT wall_dir=$WALL_DIR wall_jump_ms=$WALL_JUMP_MS"
echo "head=$(git -C "$OPENCLAW_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo ""

# Run the shipped CLI entry: `openclaw daemon install` goes through
# runDaemonInstall -> installLaunchAgent -> bootstrapLaunchAgentOrThrow.
# The ESM loader patches launchd-runtime.ts (OLD=Date.now+WALL_JUMP_MS) and
# launchd-exec.ts (force bootstrap EIO). Real launchctl for other commands,
# real monotonic clock, real Gateway config plumbing.
START_MS=$(node -e 'console.log(Date.now())')
PROOF_VARIANT="$VARIANT" WALL_JUMP_MS="$WALL_JUMP_MS" PROOF_FORCE_EIO="1" \
  OPENCLAW_LAUNCHD_LABEL="ai.openclaw.proof" \
  node --import tsx --loader "$LOADER" \
  "$OPENCLAW_DIR/src/entry.ts" daemon install --allow-unconfigured --json \
  > "/tmp/proof-v2-$VARIANT-$WALL_DIR.stdout" 2> "/tmp/proof-v2-$VARIANT-$WALL_DIR.stderr" \
  || true
END_MS=$(node -e 'console.log(Date.now())')
ELAPSED=$((END_MS - START_MS))

STDOUT=$(cat "/tmp/proof-v2-$VARIANT-$WALL_DIR.stdout" 2>/dev/null || true)
STDERR=$(cat "/tmp/proof-v2-$VARIANT-$WALL_DIR.stderr" 2>/dev/null || true)

echo "[proof] elapsed=${ELAPSED}ms"
echo "[proof] stdout (last 15 lines):"
echo "$STDOUT" | tail -15
echo ""
echo "[proof] stderr (last 15 lines):"
echo "$STDERR" | tail -15
echo ""

# Extract the outcome: did bootstrap fail (deadline fired) or succeed?
if echo "$STDOUT$STDERR" | grep -q "launchctl bootstrap failed"; then
  OUTCOME="rejected: launchctl bootstrap failed (deadline fired)"
elif echo "$STDOUT" | grep -q '"ok": true'; then
  OUTCOME="resolved/installed"
else
  OUTCOME="pending-or-other"
fi

echo "VERDICT[$VARIANT][$WALL_DIR wall_jump=${WALL_JUMP_MS}ms] elapsed=${ELAPSED}ms outcome=$OUTCOME"

# Cleanup any installed proof service
launchctl bootout "user/$(id -u)/ai.openclaw.proof" 2>/dev/null || true
