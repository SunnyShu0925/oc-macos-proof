#!/bin/bash
# Real latest-stable -> candidate upgrade of the Gateway service, on one HOME.
#
# The old side is the packaged app built from tag v2026.11.10 and the new side is
# the packaged app built from the PR branch; each side runs its own bundled runtime.
# Nothing here writes the LaunchAgent or the runtime pin by hand: the old build's
# CLI writes both, and the new build's CLI has to read the same state back.
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
PIN_DB="$HOME/.openclaw/control/services.sqlite"
BUNDLE_ID="ai.openclaw.mac"
mkdir -p "$OUT"

fail=0
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label"; fail=1; fi
}
sha() { if [ -f "$1" ]; then shasum -a 256 "$1" | awk '{print $1}'; else echo "ABSENT"; fi; }

# The packaging steps drop this marker so startup never installs behind the
# captured run's back; the install under test has to be the one that writes.
rm -f "$HOME/.openclaw/disable-launchagent"
echo "HOME=$HOME"
echo "STATE_DIR=${OPENCLAW_STATE_DIR:-<unset>}"
echo "CONFIG_PATH=${OPENCLAW_CONFIG_PATH:-<unset>}"

echo "==== before: install with the latest stable build ===="
echo "old runtime: $OLD_RT"
echo "OLD_BUN=$("$OLD_RT/bin/bun" --version 2>&1)"
mkdir -p "$HOME/.openclaw"
cat > "$HOME/.openclaw/openclaw.json" <<'JSON'
{
  "gateway": { "mode": "local", "port": 18789, "auth": { "mode": "none" } }
}
JSON

# An explicit runtime is what makes the CLI record a runtime pin, so the pin this
# run preserves is one the shipping build actually wrote.
"$OLD_RT/bin/bun" "$OLD_MJS" gateway install --runtime bun --runtime-path "$OLD_RT/bin/bun" \
  > "$OUT/install-old.log" 2>&1
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
PLIST_BEFORE=$(sha "$PLIST")
DB_BEFORE=$(sha "$PIN_DB")
echo "PLIST=$PLIST"
echo "PLIST_SHA_BEFORE=$PLIST_BEFORE"
echo "PIN_DB=$PIN_DB"
echo "PIN_DB_SHA_BEFORE=$DB_BEFORE"
cp "$PLIST" "$OUT/plist-before.plist"
plutil -p "$PLIST" > "$OUT/plist-before.txt" 2>&1
head -25 "$OUT/plist-before.txt"
echo "--- old runtime intent ---"
"$OLD_RT/bin/bun" "$OLD_MJS" gateway status --runtime-intent-only --json > "$OUT/intent-old.json" 2>&1
head -3 "$OUT/intent-old.json"
echo "--- resume command record before the upgrade ---"
echo "RESUME_BEFORE=$(defaults read "$BUNDLE_ID" gatewayNodeResumeCommand 2>/dev/null || echo ABSENT)"
echo "--- a gateway is really up on the old build ---"
"$OLD_RT/bin/bun" "$OLD_MJS" gateway status > "$OUT/gateway-status-old.log" 2>&1
grep -E "Port 18789|Listening|running" "$OUT/gateway-status-old.log" | head -4

echo "==== after: the candidate reads the same state back ===="
echo "new runtime: $NEW_RT"
echo "NEW_BUN=$("$NEW_RT/bin/bun" --version 2>&1)"
echo "--- new runtime intent ---"
"$NEW_RT/bin/bun" "$NEW_MJS" gateway status --runtime-intent-only --json > "$OUT/intent-new.json" 2>&1
head -3 "$OUT/intent-new.json"
echo "--- new status ---"
"$NEW_RT/bin/bun" "$NEW_MJS" status --json > "$OUT/status-new.json" 2>&1
head -3 "$OUT/status-new.json"
echo "--- new gateway status ---"
"$NEW_RT/bin/bun" "$NEW_MJS" gateway status > "$OUT/gateway-status-new.log" 2>&1
tail -12 "$OUT/gateway-status-new.log"

PLIST_AFTER=$(sha "$PLIST")
DB_AFTER=$(sha "$PIN_DB")
echo "PLIST_SHA_AFTER=$PLIST_AFTER"
echo "PIN_DB_SHA_AFTER=$DB_AFTER"
cp "$PLIST" "$OUT/plist-after.plist"
plutil -p "$PLIST" > "$OUT/plist-after.txt" 2>&1
echo "RESUME_AFTER=$(defaults read "$BUNDLE_ID" gatewayNodeResumeCommand 2>/dev/null || echo ABSENT)"

# The two CLIs report their own version and entrypoint, so only the service
# subtree is compared: that is the part the upgrade must leave untouched.
cat > "$OUT/intent-compare.py" <<'PY'
import json
import sys


def service(path):
    with open(path) as handle:
        return json.load(handle).get("service", {})


before = service(sys.argv[1])
after = service(sys.argv[2])
intent_before = before.get("runtimeIntent") or {}
intent_after = after.get("runtimeIntent") or {}
print("INTENT_STATUS_BEFORE=" + str(intent_before.get("status")))
print("INTENT_STORED_BEFORE=" + str(intent_before.get("stored")))
print("INTENT_REVISION_BEFORE=" + str(intent_before.get("revision")))
print("INTENT_DEFINITION_BEFORE=" + str(intent_before.get("definition")))
print("INTENT_PIN_PATH_BEFORE=" + str((intent_before.get("pin") or {}).get("path")))
print("INTENT_REVISION_AFTER=" + str(intent_after.get("revision")))
print("SERVICE_INTENT_EQUAL=" + ("1" if before == after else "0"))
PY
python3 "$OUT/intent-compare.py" "$OUT/intent-old.json" "$OUT/intent-new.json" \
  | tee "$OUT/intent-compare.txt"
INTENT_COMPARE=$(cat "$OUT/intent-compare.txt")
BEFORE_REV=$(echo "$INTENT_COMPARE" | grep '^INTENT_REVISION_BEFORE=' | cut -d= -f2-)
AFTER_REV=$(echo "$INTENT_COMPARE" | grep '^INTENT_REVISION_AFTER=' | cut -d= -f2-)

echo "==== verdict ===="
check "the old build installed the LaunchAgent" test -f "$OUT/plist-before.plist"
check "the old build reported success" test "$OLD_EXIT" = "0"
check "LaunchAgent is byte-identical after the candidate ran" test "$PLIST_BEFORE" = "$PLIST_AFTER"
check "LaunchAgent still declares program arguments" grep -q "ProgramArguments" "$OUT/plist-after.txt"
check "LaunchAgent still points at the runtime the old build installed" \
  grep -qF "$OLD_RT" "$OUT/plist-after.txt"
check "the old build recorded a runtime pin" \
  grep -q '^INTENT_STATUS_BEFORE=known' <<<"$INTENT_COMPARE"
check "the old build stored that pin" grep -q '^INTENT_STORED_BEFORE=True' <<<"$INTENT_COMPARE"
check "the pin names the runtime the old build installed" \
  grep -qF "INTENT_PIN_PATH_BEFORE=$OLD_RT/bin/bun" <<<"$INTENT_COMPARE"
check "the pin store is byte-identical after the candidate ran" test "$DB_BEFORE" = "$DB_AFTER"
check "the candidate reports the same service intent" \
  grep -q '^SERVICE_INTENT_EQUAL=1' <<<"$INTENT_COMPARE"
check "the candidate reads the same pin revision" \
  test -n "${BEFORE_REV:-}" -a "${AFTER_REV:-x}" = "${BEFORE_REV:-y}"
check "candidate gateway status did not report a broken service" \
  bash -c "! grep -qiE 'not installed|missing plist|corrupt' '$OUT/gateway-status-new.log'"

echo "--- records this headless run cannot exercise ---"
if [ "$DB_BEFORE" = "ABSENT" ]; then
  echo "PIN_DB_NOTE=no pin store was written, so pin preservation is vacuous here"
else
  echo "PIN_DB_NOTE=pin store present and compared byte for byte"
fi
echo "RESUME_NOTE=the resume command is written by the app's own service install, so a CLI-only run cannot seed or check it"

echo "UPGRADE_FAIL=$fail"
exit "$fail"
