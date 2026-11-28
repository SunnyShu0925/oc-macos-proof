#!/bin/bash
# PortGuardian PR #201553 - absent-service migration with an unreadable port.
#
#   migration-absent-capture.sh <label>
#
# The reviewer's Rev 10 objection: the upgrade fixture installed pinned Bun
# (--runtime bun --runtime-path), which creates a runtime pin. The changed
# absent-service migration path (ManagedNodeGatewayMigration.captureAbsentService)
# requires an *unpinned* managed Node installation and no pin record before it
# reaches its inspection branch. This capture sets up exactly that:
#
#   1. v2026.11.10's CLI installs the LaunchAgent with the default Node runtime
#      (no --runtime, no --runtime-path), so no pin is recorded.
#   2. The LaunchAgent plist is removed (bootout + rm), but the resume command
#      stays in defaults, so candidate sees arguments.isEmpty -> captureAbsentService.
#   3. A broken lsof stub is placed on PATH; the candidate app is launched normally.
#   4. captureAbsentService reads .unknown and throws "The Gateway port could not
#      be inspected; the existing owner was preserved." No child starts.
#
# Env: APP_PATH, OLD_RUNTIME, OUT_DIR, PROBE_DIR, GATEWAY_PORT, BUNDLE_ID.
set -uo pipefail

LABEL="${1:?usage: migration-absent-capture.sh <label>}"
APP="${APP_PATH:?APP_PATH required}"
OLD_RT="${OLD_RUNTIME:?OLD_RUNTIME required}"
OLD_MJS="$OLD_RT/lib/node_modules/openclaw/openclaw.mjs"
OUT="${OUT_DIR:-/tmp/pg201553/migration-absent}"
PROBE_DIR="${PROBE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
PORT="${GATEWAY_PORT:-18789}"
BUNDLE_ID="${BUNDLE_ID:-ai.openclaw.mac}"
REAL_LSOF=/usr/sbin/lsof
PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
STATE="$HOME/.openclaw"
PIN_DB="$STATE/control/services.sqlite"
fail=0

mkdir -p "$OUT"
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label"; fail=$((fail + 1)); fi
}
say() { echo; echo "==== $* ===="; }
sha() { if [ -f "$1" ]; then shasum -a 256 "$1" | awk '{print $1}'; else echo "ABSENT"; fi; }
run_limited() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@" 2>&1 || true; }

say "capture label=$LABEL"
echo "APP=$APP"
echo "APP_BINARY_SHA=$(shasum -a 256 "$APP/Contents/MacOS/OpenClaw" | awk '{print $1}')"

# ---------------------------------------------------------------- clean slate
say "clean slate"
pkill -9 -f "openclaw.mjs gateway" 2>/dev/null || true
pkill -9 -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null || true
pkill -9 -f "OpenClaw.app/Contents/Resources/runtime" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
for w in $(seq 1 15); do
  remaining=$(pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" | wc -l | tr -d ' ')
  listener=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" -eq 0 ] && [ "$listener" -eq 0 ] && break
  pkill -9 -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null || true
  pkill -9 -f "openclaw.mjs gateway" 2>/dev/null || true
  sleep 1
done
rm -rf "/tmp/openclaw-$(id -u)-app-instances" 2>/dev/null || true
rm -f "$STATE/disable-launchagent" 2>/dev/null || true
rm -f "$PLIST" 2>/dev/null || true
rm -f "$PIN_DB" 2>/dev/null || true
defaults delete "$BUNDLE_ID" gatewayNodeResumeCommand 2>/dev/null || true
sleep 1
echo "LISTENERS_BEFORE=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')"
echo "PLIST_PRESENT=$( [ -e "$PLIST" ] && echo yes || echo no )"
echo "PIN_DB_PRESENT=$( [ -e "$PIN_DB" ] && echo yes || echo no )"

# ---------------------------------------------------------------- old install (Node, no pin)
say "install with the latest stable build (default Node runtime, no pin)"
mkdir -p "$STATE"
cat > "$STATE/openclaw.json" <<'JSON'
{
  "gateway": { "mode": "local", "port": 18789, "auth": { "mode": "none" } }
}
JSON
# Default runtime: no --runtime, no --runtime-path. This creates a managed Node
# LaunchAgent with NO runtime pin, which is what captureAbsentService requires.
"$OLD_RT/bin/bun" "$OLD_MJS" gateway install > "$OUT/install-old.log" 2>&1
OLD_EXIT=$?
echo "OLD_INSTALL_EXIT=$OLD_EXIT"
tail -10 "$OUT/install-old.log"
echo "PLIST_AFTER_OLD=$( [ -e "$PLIST" ] && echo yes || echo no )"
echo "PIN_DB_AFTER_OLD=$( [ -e "$PIN_DB" ] && echo yes || echo no )"

if [ ! -e "$PLIST" ]; then
  echo "NO_PLIST_AFTER_OLD_INSTALL"
  echo "PROOF_FAIL=1"
  exit 1
fi

# Snapshot the old state
PLIST_SHA=$(sha "$PLIST")
echo "PLIST_SHA=$PLIST_SHA"
cp "$PLIST" "$OUT/plist-before.plist"
plutil -p "$PLIST" > "$OUT/plist-before.txt" 2>&1
echo "--- plist ProgramArguments ---"
grep -A 10 "ProgramArguments" "$OUT/plist-before.txt" | head -12
echo "--- runtime intent (should show no pin) ---"
"$OLD_RT/bin/bun" "$OLD_MJS" gateway status --runtime-intent-only --json > "$OUT/intent-old.json" 2>&1
cat "$OUT/intent-old.json" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    ri=d.get('service',{}).get('runtimeIntent',{})
    print('status:',ri.get('status'))
    print('stored:',ri.get('stored'))
    print('pin:',ri.get('pin'))
except: print('parse error')
" 2>&1 || true

# Stop the old Gateway
"$OLD_RT/bin/bun" "$OLD_MJS" gateway stop > "$OUT/stop-old.log" 2>&1 || true
sleep 2

# ---------------------------------------------------------------- simulate absent service
say "remove the LaunchAgent plist (service absent), keep the resume command"
launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
rm -f "$PLIST"
echo "PLIST_AFTER_REMOVE=$( [ -e "$PLIST" ] && echo yes || echo no )"
echo "RESUME_CMD_PRESENT=$(defaults read "$BUNDLE_ID" gatewayNodeResumeCommand >/dev/null 2>&1 && echo yes || echo no)"
echo "PIN_DB_AFTER_REMOVE=$( [ -e "$PIN_DB" ] && echo yes || echo no )"
echo "LISTENERS_AFTER_STOP=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- broken lsof stub
POISON="$OUT/poison"
rm -rf "$POISON"; mkdir -p "$POISON"
CALLS="$OUT/stub-calls.log"; : > "$CALLS"
cat > "$POISON/lsof" <<'STUB'
#!/bin/bash
echo "$*" >> "$CALLS"
echo "lsof: proc_listpids failed: Cannot allocate memory" >&2
exit 1
STUB
chmod +x "$POISON/lsof"

# ---------------------------------------------------------------- onboarding seen
defaults write "$BUNDLE_ID" openclaw.onboardingSeen -bool true 2>/dev/null || true
defaults write "$BUNDLE_ID" openclaw.onboardingVersion -int 99 2>/dev/null || true

# ---------------------------------------------------------------- launch candidate
say "launch the candidate app (broken lsof, absent service)"
LOG="$OUT/app.log"
: > "$LOG"
PATH="$POISON:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$APP/Contents/MacOS/OpenClaw" > "$LOG" 2>&1 &
APP_PID=$!
echo "APP_PID=$APP_PID"

# Wait for the app to reach the migration path
sleep 15
EARLY_CALLS=$(wc -l < "$CALLS" | tr -d ' ')
echo "STUB_CALLS_AT_LAUNCH=$EARLY_CALLS"
if [ "$EARLY_CALLS" -eq 0 ]; then
  for w in $(seq 1 15); do
    sleep 3
    EARLY_CALLS=$(wc -l < "$CALLS" | tr -d ' ')
    [ "$EARLY_CALLS" -ge 1 ] && break
  done
  echo "STUB_CALLS_AFTER_WAIT=$EARLY_CALLS"
fi

# Poll for child/listener
CHILD_MAX=0
LISTENER_MAX=0
for tick in $(seq 1 20); do
  sleep 3
  listener_lines=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null | grep '^p' | sort -u)
  listener_count=$(echo "$listener_lines" | grep -c '^p')
  child=0
  for lp in $listener_lines; do
    lpid=${lp#p}
    [ "$lpid" = "$APP_PID" ] && continue
    [ -n "$lpid" ] && child=$((child + 1))
  done
  [ "$child" -gt "$CHILD_MAX" ] && CHILD_MAX=$child
  [ "$listener_count" -gt "$LISTENER_MAX" ] && LISTENER_MAX=$listener_count
  if [ "$tick" -ge 10 ]; then
    echo "poll $tick: child=$child listener=$listener_count"
    break
  fi
done

say "observed"
STUB_CALLS=$(wc -l < "$CALLS" | tr -d ' ')
echo "STUB_CALLS=$STUB_CALLS"
echo "CHILD_MAX=$CHILD_MAX"
echo "LISTENER_MAX=$LISTENER_MAX"
echo "DISABLE_MARKER_AFTER=$( [ -e "$STATE/disable-launchagent" ] && echo present || echo absent )"
echo "PLIST_AFTER=$( [ -e "$PLIST" ] && echo written || echo absent )"
echo "--- stub invocations ---"
head -5 "$CALLS"
echo "--- ps: gateway-ish processes ---"
ps -Ao pid,command | grep -E "openclaw.mjs gateway|OpenClaw.app/Contents/MacOS" | grep -v grep | head -6 || echo "(none)"

say "unified log"
run_limited 90 log show --last 5m --style compact \
  --predicate 'process == "OpenClaw"' \
  > "$OUT/oslog.txt" 2>&1 || true
grep -iE 'could not.*inspect|could not.*determine|existing owner was preserved|port could not|migration|absent|externally managed|five failed|child.*launch|attach|gateway.*start|retry' \
  "$OUT/oslog.txt" | tail -25 || echo "(no unified-log matches)"

say "verdict"
check "the old build installed the LaunchAgent" test -f "$OUT/plist-before.plist"
check "the old build reported success" test "$OLD_EXIT" = "0"
check "the old install used Node (not Bun)" grep -q "node" "$OUT/plist-before.txt"
check "no runtime pin was recorded" bash -c "! grep -q '\"pin\"' '$OUT/intent-old.json'"
check "the plist was removed to simulate absent service" test ! -e "$PLIST"
check "the resume command survived the plist removal" \
  bash -c "defaults read '$BUNDLE_ID' gatewayNodeResumeCommand >/dev/null 2>&1"
check "the shipped probe ran through the poisoned PATH" test "$STUB_CALLS" -ge 1
check "the candidate did not spawn a Gateway child" test "$CHILD_MAX" -eq 0
check "no listener appeared on the unreadable port" test "$LISTENER_MAX" -eq 0
# The key assertion: captureAbsentService saw .unknown and threw the preservation
# message, proving the changed migration path was reached and withheld custody.
check "the candidate preserved the existing owner (unknown-port migration)" \
  bash -c "grep -aqiE 'could not be inspected|existing owner was preserved|port could not' '$LOG' '$OUT/oslog.txt'"
check "startup was not refused as an externally managed Gateway" \
  bash -c "! grep -aq 'externally managed' '$LOG' '$OUT/oslog.txt'"

pkill -9 -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null || true
kill -9 "$APP_PID" 2>/dev/null || true
pkill -9 -f "openclaw.mjs gateway" 2>/dev/null || true

echo "PROOF_FAIL=$fail"
exit "$([ "$fail" -eq 0 ] && echo 0 || echo 1)"
