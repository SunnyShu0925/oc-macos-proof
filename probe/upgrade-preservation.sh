#!/bin/bash
# Real latest-stable -> candidate upgrade of the Gateway service, on one HOME.
#
# The old side is the packaged app built from tag v2026.11.10 and the new side is
# the packaged app built from the PR branch; each side runs its own bundled runtime.
# Nothing here writes the LaunchAgent or the runtime pin by hand: the old build's
# CLI does, and the new build's CLI has to read the same state back.
#
# `gateway install` refuses a non-default state dir, so this runs on the account
# home. The runner is disposable, which is why that is safe here.
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

# The packaging steps drop this marker so startup never installs behind the
# captured run's back; the install under test has to be the one that writes.
rm -f "$HOME/.openclaw/disable-launchagent"
echo "HOME=$HOME"
echo "STATE_DIR=${OPENCLAW_STATE_DIR:-<unset>}"
echo "CONFIG_PATH=${OPENCLAW_CONFIG_PATH:-<unset>}"

echo "==== before: install with the latest stable build ===="
echo "old runtime: $OLD_RT"
OLD_VERSION=$("$OLD_RT/bin/bun" --version 2>&1)
echo "OLD_BUN=$OLD_VERSION"
mkdir -p "$HOME/.openclaw"
cat > "$HOME/.openclaw/openclaw.json" <<'JSON'
{
  "gateway": { "mode": "local", "port": 18789, "auth": { "mode": "none" } }
}
JSON

"$OLD_RT/bin/bun" "$OLD_MJS" gateway install > "$OUT/install-old.log" 2>&1
OLD_EXIT=$?
echo "OLD_INSTALL_EXIT=$OLD_EXIT"
tail -15 "$OUT/install-old.log"

if [ ! -f "$PLIST" ]; then
  echo "NO_PLIST_AFTER_OLD_INSTALL"
  ls -la "$HOME/Library/LaunchAgents" 2>/dev/null || true
  echo "UPGRADE_FAIL=1"
  exit 1
fi

echo "==== state written by the old build ===="
BEFORE_SHA=$(shasum -a 256 "$PLIST" | awk '{print $1}')
echo "PLIST=$PLIST"
echo "PLIST_SHA_BEFORE=$BEFORE_SHA"
cp "$PLIST" "$OUT/plist-before.plist"
plutil -p "$PLIST" > "$OUT/plist-before.txt" 2>&1
head -30 "$OUT/plist-before.txt"
echo "--- old runtime intent ---"
"$OLD_RT/bin/bun" "$OLD_MJS" status --runtime-intent-only --json > "$OUT/intent-old.json" 2>&1
head -3 "$OUT/intent-old.json"
echo "--- resume command record before the upgrade ---"
BEFORE_RESUME=$(defaults read "$BUNDLE_ID" gatewayNodeResumeCommand 2>/dev/null || echo "ABSENT")
echo "RESUME_BEFORE=$BEFORE_RESUME"

echo "==== after: read the same state with the candidate build ===="
echo "new runtime: $NEW_RT"
NEW_VERSION=$("$NEW_RT/bin/bun" --version 2>&1)
echo "NEW_BUN=$NEW_VERSION"
echo "--- new runtime intent ---"
"$NEW_RT/bin/bun" "$NEW_MJS" status --runtime-intent-only --json > "$OUT/intent-new.json" 2>&1
head -3 "$OUT/intent-new.json"
echo "--- new status ---"
"$NEW_RT/bin/bun" "$NEW_MJS" status --json > "$OUT/status-new.json" 2>&1
head -3 "$OUT/status-new.json"
echo "--- new gateway status ---"
"$NEW_RT/bin/bun" "$NEW_MJS" gateway status > "$OUT/gateway-status-new.log" 2>&1
tail -12 "$OUT/gateway-status-new.log"

AFTER_SHA=$(shasum -a 256 "$PLIST" | awk '{print $1}')
echo "PLIST_SHA_AFTER=$AFTER_SHA"
cp "$PLIST" "$OUT/plist-after.plist"
plutil -p "$PLIST" > "$OUT/plist-after.txt" 2>&1
AFTER_RESUME=$(defaults read "$BUNDLE_ID" gatewayNodeResumeCommand 2>/dev/null || echo "ABSENT")
echo "RESUME_AFTER=$AFTER_RESUME"

echo "==== verdict ===="
check "the old build installed the LaunchAgent" test -f "$OUT/plist-before.plist"
check "the old build reported success" test "$OLD_EXIT" = "0"
check "LaunchAgent is byte-identical after the candidate ran" test "$BEFORE_SHA" = "$AFTER_SHA"
check "LaunchAgent still declares program arguments" grep -q "ProgramArguments" "$OUT/plist-after.txt"
check "LaunchAgent still names the bundled runtime" grep -Eq "bun|openclaw" "$OUT/plist-after.txt"
check "runtime intent still resolves after the candidate ran" \
  grep -Eq '"status": *"known"' "$OUT/intent-new.json"
check "runtime pin revision survived the candidate" \
  grep -Eq '"revision": *"[^"]+"' "$OUT/intent-new.json"
check "candidate gateway status did not report a broken service" \
  bash -c "! grep -qiE 'not installed|missing plist|corrupt' '$OUT/gateway-status-new.log'"

echo "--- what the resume record can and cannot show headlessly ---"
if [ "$BEFORE_RESUME" = "ABSENT" ]; then
  echo "RESUME_NOTE=no record was present, so this run says nothing about preserving it"
else
  check "resume command preserved" test "$AFTER_RESUME" = "$BEFORE_RESUME"
fi

echo "UPGRADE_FAIL=$fail"
exit "$fail"
