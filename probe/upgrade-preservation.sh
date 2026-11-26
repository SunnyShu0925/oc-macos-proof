#!/bin/bash
# Real latest-stable -> candidate upgrade of the Gateway service, on one HOME.
#
# The old side is the packaged app built from tag v2026.11.10 and the new side is
# the packaged app built from the PR branch; each side runs its own bundled runtime.
# Nothing here writes the LaunchAgent or the runtime pin by hand: the old build's
# CLI does, and the new build's CLI has to read the same state back.
set -uo pipefail

OUT="${OUT_DIR:?OUT_DIR required}"
OLD_RT="${OLD_RUNTIME:?OLD_RUNTIME required}"
NEW_RT="${NEW_RUNTIME:?NEW_RUNTIME required}"
OLD_MJS="$OLD_RT/lib/node_modules/openclaw/openclaw.mjs"
NEW_MJS="$NEW_RT/lib/node_modules/openclaw/openclaw.mjs"
PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
BUNDLE_ID="ai.openclaw.mac"
mkdir -p "$OUT"

fail=0
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label"; fail=1; fi
}

echo "==== before: install with the latest stable build ===="
echo "old runtime: $OLD_RT"
"$OLD_RT/bin/bun" --version || exit 1
mkdir -p "$HOME/.openclaw"
cat > "$HOME/.openclaw/openclaw.json" <<'JSON'
{
  "gateway": { "mode": "local", "port": 18789, "auth": { "mode": "none" } }
}
JSON

"$OLD_RT/bin/bun" "$OLD_MJS" gateway install 2>&1 | tail -30
echo "OLD_INSTALL_EXIT=$?"

if [ ! -f "$PLIST" ]; then
  echo "NO_PLIST_AFTER_OLD_INSTALL"
  ls -la "$HOME/Library/LaunchAgents" 2>/dev/null || true
  exit 1
fi

echo "==== state written by the old build ===="
BEFORE_SHA=$(shasum -a 256 "$PLIST" | awk '{print $1}')
echo "PLIST=$PLIST"
echo "PLIST_SHA_BEFORE=$BEFORE_SHA"
plutil -p "$PLIST" | head -40
cp "$PLIST" "$OUT/plist-before.plist"
echo "--- old runtime intent ---"
"$OLD_RT/bin/bun" "$OLD_MJS" status --runtime-intent-only --json 2>&1 | tee "$OUT/intent-old.json" | head -5
echo "--- old resume command record ---"
"$OLD_RT/bin/bun" "$OLD_MJS" --version 2>&1 | head -2
defaults read "$BUNDLE_ID" gatewayNodeResumeCommand 2>/dev/null || echo "NO_RESUME_COMMAND_YET"

# The app owns this record; the upgrade path must not clobber an existing value.
# Seeded here only because no headless run of the old GUI can type it in, which is
# stated as a limit in the PR body rather than presented as an app capture.
SEEDED_RESUME="/Applications/OpenClaw.app/Contents/Resources/runtime/bin/bun gateway run --port 18789"
defaults write "$BUNDLE_ID" gatewayNodeResumeCommand "$SEEDED_RESUME"
echo "SEEDED_RESUME=$SEEDED_RESUME"

echo "==== after: read the same state with the candidate build ===="
echo "new runtime: $NEW_RT"
"$NEW_RT/bin/bun" --version || exit 1
echo "--- new runtime intent ---"
"$NEW_RT/bin/bun" "$NEW_MJS" status --runtime-intent-only --json 2>&1 | tee "$OUT/intent-new.json" | head -5
echo "--- new status ---"
"$NEW_RT/bin/bun" "$NEW_MJS" status --json 2>&1 | tee "$OUT/status-new.json" | head -20
echo "--- new gateway status ---"
"$NEW_RT/bin/bun" "$NEW_MJS" gateway status 2>&1 | tail -15

AFTER_SHA=$(shasum -a 256 "$PLIST" | awk '{print $1}')
echo "PLIST_SHA_AFTER=$AFTER_SHA"
cp "$PLIST" "$OUT/plist-after.plist"
plutil -p "$PLIST" | head -40
AFTER_RESUME=$(defaults read "$BUNDLE_ID" gatewayNodeResumeCommand 2>/dev/null || echo "MISSING")
echo "RESUME_AFTER=$AFTER_RESUME"

echo "==== verdict ===="
check "LaunchAgent plist is byte-identical after the candidate ran" test "$BEFORE_SHA" = "$AFTER_SHA"
check "runtime intent still resolves after the candidate ran" \
  grep -Eq '"status": *"known"' "$OUT/intent-new.json"
check "runtime pin revision preserved" \
  grep -Eq '"revision": *"[^"]+"' "$OUT/intent-new.json"
check "resume command preserved" test "$AFTER_RESUME" = "$SEEDED_RESUME"
plutil -p "$PLIST" > "$OUT/plist-dump.txt" 2>&1 || true
check "LaunchAgent still declares program arguments" grep -q "ProgramArguments" "$OUT/plist-dump.txt"
check "LaunchAgent still names the runtime" grep -qE "bun|openclaw" "$OUT/plist-dump.txt"

echo "UPGRADE_FAIL=$fail"
exit "$fail"
