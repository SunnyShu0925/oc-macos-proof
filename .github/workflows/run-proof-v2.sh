#!/usr/bin/env bash
# PR #175204 diamond proof v2: shipped `openclaw daemon install` CLI entry.
# Exercises bootstrapLaunchAgentOrThrow through the shipped CLI command
# (node --import tsx src/entry.ts daemon install) instead of importing the
# function directly, so the proof path is the shipped entry point.
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

# Prepare a pending-teardown scenario: bootstrap a probe plist into the user
# domain so the subsequent `openclaw daemon install` bootstrap hits a real EIO
# ("Bootstrap failed: 5: Input/output error") that isLaunchctlBootstrapPendingTeardown
# classifies as pending teardown. Real launchctl transport, real monotonic clock.
UID_NUM="$(id -u)"
PROBE_PLIST="/tmp/ai.openclaw.probe.$$.plist"
cat > "$PROBE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>ai.openclaw.proof</string>
<key>ProgramArguments</key><array><string>/bin/true</string></array></dict></plist>
EOF
OPENCLAW_LAUNCHD_LABEL="ai.openclaw.proof" launchctl bootstrap "user/$UID_NUM" "$PROBE_PLIST" 2>/dev/null || true
echo "[proof] pending-teardown probe bootstrapped (real EIO expected on next bootstrap)"
echo ""

# Run the shipped CLI entry: `openclaw daemon install` goes through
# runDaemonInstall -> installLaunchAgent -> bootstrapLaunchAgentOrThrow.
# The ESM loader patches launchd-runtime.ts so OLD uses Date.now()+WALL_JUMP_MS
# and FIXED uses performance.now() (untouched). Real launchctl child process,
# real monotonic clock, real Gateway config plumbing.
START_MS=$(node -e 'console.log(Date.now())')
PROOF_VARIANT="$VARIANT" WALL_JUMP_MS="$WALL_JUMP_MS" \
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
echo "[proof] stdout (last 20 lines):"
echo "$STDOUT" | tail -20
echo ""
echo "[proof] stderr (last 20 lines):"
echo "$STDERR" | tail -20
echo ""

# Extract the outcome: did bootstrap fail (deadline fired) or is it still pending?
if echo "$STDERR" | grep -q "launchctl bootstrap failed"; then
  OUTCOME="rejected: launchctl bootstrap failed"
elif echo "$STDOUT" | grep -q "launchctl bootstrap failed"; then
  OUTCOME="rejected: launchctl bootstrap failed"
elif echo "$STDOUT" | grep -q '"installed"\|"ok"'; then
  OUTCOME="resolved/installed"
else
  OUTCOME="pending-or-other"
fi

echo "VERDICT[$VARIANT][$WALL_DIR wall_jump=${WALL_JUMP_MS}ms] elapsed=${ELAPSED}ms outcome=$OUTCOME"

# Cleanup probe
launchctl bootout "user/$UID_NUM/ai.openclaw.proof" 2>/dev/null || true
rm -f "$PROBE_PLIST"
