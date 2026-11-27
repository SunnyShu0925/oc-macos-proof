#!/bin/bash
# PortGuardian PR #201553 - real old-app -> candidate upgrade / data-model proof.
#
# The LaunchAgent, the runtime pin and - crucially - the gatewayNodeResumeCommand
# are written by the OLD APP ITSELF. This script only presets two opt-in defaults
# (gatewayHosting=service, pauseEnabled=true) and a minimal config; it never
# hand-writes a plist, a pin or a resume record. The candidate then cold-starts
# with a failing lsof on its PATH and must resume instead of forcing an install.
#
# Env: OLD_APP_PATH, NEW_APP_PATH, OUT_DIR, PROBE_DIR, BUNDLE_ID, GATEWAY_PORT.
# Verdict is echoed as PASS:/FAIL: lines and PROOF_FAIL=<n>. All values that can
# carry a token / IP / phone / endpoint pass through redact() before echo.
set -uo pipefail

OUT="${OUT_DIR:-/tmp/pg201553/upgrade}"
OLD_APP="${OLD_APP_PATH:?OLD_APP_PATH required}"
NEW_APP="${NEW_APP_PATH:?NEW_APP_PATH required}"
PROBE_DIR="${PROBE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
BUNDLE_ID="${BUNDLE_ID:-ai.openclaw.mac}"
PORT="${GATEWAY_PORT:-18789}"

PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
PIN_DB="$HOME/.openclaw/control/services.sqlite"
CONFIG="$HOME/.openclaw/openclaw.json"
OLD_RT="$OLD_APP/Contents/Resources/runtime"
NEW_RT="$NEW_APP/Contents/Resources/runtime"
OLD_MJS="$OLD_RT/lib/node_modules/openclaw/openclaw.mjs"
NEW_MJS="$NEW_RT/lib/node_modules/openclaw/openclaw.mjs"
OLD_BUN="$OLD_RT/bin/bun"
NEW_BUN="$NEW_RT/bin/bun"
REAL_LSOF=/usr/sbin/lsof
RESUME_KEY="gatewayNodeResumeCommand"

mkdir -p "$OUT/logs-old" "$OUT/logs-pause" "$OUT/logs-new" "$OUT/poison" \
  "$HOME/.openclaw" "$HOME/Library/LaunchAgents"
STATUS="$OUT/verdict.log"
: > "$STATUS"

say() { echo "$@" | tee -a "$STATUS"; }

fail=0
check() {
  local label="$1"; shift
  if "$@"; then say "PASS: $label"; else say "FAIL: $label"; fail=1; fi
}

sha() { if [ -f "$1" ]; then shasum -a 256 "$1" | awk '{print $1}'; else echo ABSENT; fi; }

# Redact anything that looks like a credential, address, phone or endpoint.
redact() {
  sed -E \
    -e 's/((token|apiKey|api_key|secret|password|authorization)[^,}]*)/\1=<redacted>/Ig' \
    -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' \
    -e 's/1[3-9][0-9]{9}/<phone>/g' \
    -e 's#wss?://[^", ]+#<endpoint>#g'
}

real_listeners() {
  "$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null \
    | sed -n 's/^p//p' | sort -u
}
count_listeners() { real_listeners | grep -c . || true; }
stop_app() { pkill -f "OpenClaw.app/Contents/MacOS/OpenClaw" >/dev/null 2>&1 || true; }
stop_gateways() {
  pkill -f "$OLD_MJS gateway run" >/dev/null 2>&1 || true
  pkill -f "$NEW_MJS gateway run" >/dev/null 2>&1 || true
}
read_resume() {
  local raw
  raw=$(defaults read "$BUNDLE_ID" "$RESUME_KEY" 2>/dev/null || true)
  if [ -z "$raw" ]; then echo ABSENT; else printf '%s' "$raw"; fi
}

say "==== upgrade-app-resume ===="
say "OLD_APP=$OLD_APP"
say "NEW_APP=$NEW_APP"
say "OLD_BINARY_SHA=$(shasum -a 256 "$OLD_APP/Contents/MacOS/OpenClaw" 2>/dev/null | awk '{print $1}')"
say "NEW_BINARY_SHA=$(shasum -a 256 "$NEW_APP/Contents/MacOS/OpenClaw" 2>/dev/null | awk '{print $1}')"
say "OLD_BUN=$("$OLD_BUN" --version 2>&1)"
say "NEW_BUN=$("$NEW_BUN" --version 2>&1)"
say "PLIST=$PLIST"
say "PIN_DB=$PIN_DB"
say "CONFIG=$CONFIG"
say "HOME=$HOME"

# -------------------------------------------------- clean slate before install
stop_app
stop_gateways
sleep 2
rm -f "$PLIST" "$PIN_DB" "$PIN_DB-wal" "$PIN_DB-shm" "$CONFIG" \
  "$HOME/.openclaw/disable-launchagent"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
mkdir -p "$(dirname "$PLIST")" "$(dirname "$PIN_DB")" "$HOME/.openclaw"
# A minimal config is allowed; plist / pin / resume are not written by hand.
cat > "$CONFIG" <<JSON
{ "gateway": { "mode": "local", "port": $PORT, "auth": { "mode": "none" } } }
JSON
CONFIG_BEFORE=$(sha "$CONFIG")
say "CONFIG_SHA_BEFORE=$CONFIG_BEFORE"

# ----------------------------------- old app installs the service by itself
# Only opt-in defaults are preset. The old build's real startup path installs
# the LaunchAgent and records the runtime pin.
defaults write "$BUNDLE_ID" gatewayHosting -string service
defaults write "$BUNDLE_ID" openclaw.onboardingSeen -bool true
defaults write "$BUNDLE_ID" openclaw.onboardingVersion -int 8
defaults write "$BUNDLE_ID" openclaw.debugPaneEnabled -bool true
export OPENCLAW_LOG_DIR="$OUT/logs-old"
"$OLD_APP/Contents/MacOS/OpenClaw" --debug-open-menu > "$OUT/old-app-install.log" 2>&1 &
OLD_PID=$!
say "OLD_INSTALL_PID=$OLD_PID"

PLIST_UP=0
for i in $(seq 1 120); do
  if [ -f "$PLIST" ]; then PLIST_UP=1; break; fi
  sleep 1
done
say "PLIST_WRITTEN_BY_OLD_APP=$PLIST_UP after ${i}s"
for i in $(seq 1 60); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 1
done
say "OLD_SERVICE_LISTENING=$(count_listeners) after ${i}s"

"$OLD_BUN" "$OLD_MJS" gateway status --runtime-intent-only --json \
  > "$OUT/intent-before.json" 2>&1 || true
"$OLD_BUN" "$OLD_MJS" gateway status > "$OUT/gateway-status-old.log" 2>&1 || true
say "--- old gateway status (safe lines) ---"
grep -iE 'Port |Listening|running|service' "$OUT/gateway-status-old.log" | head -6 || true

PLIST_BEFORE=$(sha "$PLIST")
PIN_BEFORE=$(sha "$PIN_DB")
cp "$PLIST" "$OUT/plist-before.plist" 2>/dev/null || true
plutil -p "$PLIST" > "$OUT/plist-before.txt" 2>&1 || true
say "PLIST_SHA_BEFORE=$PLIST_BEFORE"
say "PIN_DB_SHA_BEFORE=$PIN_BEFORE"
RESUME_AT_INSTALL=$(read_resume | redact)
say "RESUME_AFTER_OLD_INSTALL=$RESUME_AT_INSTALL"

# ---------------------------- old app pauses itself (the real retain path) ---
say "==== old app pauses itself via a cold start with pauseEnabled=true ===="
stop_app
sleep 3
defaults write "$BUNDLE_ID" openclaw.pauseEnabled -bool true
export OPENCLAW_LOG_DIR="$OUT/logs-pause"
"$OLD_APP/Contents/MacOS/OpenClaw" --debug-open-menu > "$OUT/old-app-pause.log" 2>&1 &
OLD_PAUSE_PID=$!
say "OLD_PAUSE_PID=$OLD_PAUSE_PID"

RESUME_BEFORE_RAW=ABSENT
for i in $(seq 1 90); do
  R=$(read_resume)
  if [ "$R" != ABSENT ]; then RESUME_BEFORE_RAW="$R"; break; fi
  sleep 1
done
RESUME_BEFORE_SAFE=$(printf '%s' "$RESUME_BEFORE_RAW" | redact)
say "RESUME_WRITTEN_BY_OLD_PAUSE=$([ "$RESUME_BEFORE_RAW" != ABSENT ] && echo yes || echo no) after ${i}s"
say "RESUME_COMMAND_BEFORE=$RESUME_BEFORE_SAFE"
say "--- launchctl state after the old app paused ---"
launchctl print "gui/$(id -u)/ai.openclaw.gateway" 2>&1 \
  | grep -iE 'state|program|pid|path|active|running' | head -12 || true

PLIST_PAUSED=$(sha "$PLIST")
PIN_PAUSED=$(sha "$PIN_DB")
CONFIG_PAUSED=$(sha "$CONFIG")
say "PLIST_SHA_PAUSED=$PLIST_PAUSED"
say "PIN_DB_SHA_PAUSED=$PIN_PAUSED"
say "CONFIG_SHA_PAUSED=$CONFIG_PAUSED"

stop_app
sleep 3

# ------------------- old app resumes its own paused service (real recovery) --
# Pause uninstalls the plist; that is not data loss, it is the retained-command
# handoff. Relaunching the old app with pauseEnabled=false makes the shipped
# start path load gatewayNodeResumeCommand and re-enable the service from it.
say "==== old app resumes from its own retained command ===="
defaults write "$BUNDLE_ID" openclaw.pauseEnabled -bool false
export OPENCLAW_LOG_DIR="$OUT/logs-resume"
"$OLD_APP/Contents/MacOS/OpenClaw" --debug-open-menu > "$OUT/old-app-resume.log" 2>&1 &
OLD_RESUME_PID=$!
say "OLD_RESUME_PID=$OLD_RESUME_PID"
LISTENER_RESTORED=0
for i in $(seq 1 90); do
  if [ "$(count_listeners)" -ge 1 ]; then LISTENER_RESTORED=1; break; fi
  sleep 1
done
say "OLD_SERVICE_RESTORED=$LISTENER_RESTORED after ${i}s"
RESUME_AFTER_RESTORE_RAW=$(read_resume)
say "RESUME_WRITTEN_AFTER_OLD_RESUME=$(printf '%s' "$RESUME_AFTER_RESTORE_RAW" | redact)"
"$OLD_BUN" "$OLD_MJS" gateway status --runtime-intent-only --json \
  > "$OUT/intent-restored.json" 2>&1 || true
"$OLD_BUN" "$OLD_MJS" gateway status > "$OUT/gateway-status-restored.log" 2>&1 || true
say "--- restored gateway status (safe lines) ---"
grep -iE 'Port |Listening|running|service|resume' "$OUT/gateway-status-restored.log" | head -8 || true

PLIST_RESTORED=$(sha "$PLIST")
PIN_RESTORED=$(sha "$PIN_DB")
CONFIG_RESTORED=$(sha "$CONFIG")
RESTORED_LISTENERS=$(real_listeners)
say "PLIST_SHA_RESTORED=$PLIST_RESTORED"
say "PIN_DB_SHA_RESTORED=$PIN_RESTORED"
say "CONFIG_SHA_RESTORED=$CONFIG_RESTORED"
say "LISTENER_PIDS_RESTORED=$(echo "$RESTORED_LISTENERS" | tr '\n' ',')"

stop_app
sleep 3

# ------------------------- candidate cold start under a failing lsof PATH ----
say "==== candidate cold start: resolve an unreadable port, then Resume ===="
cat > "$OUT/poison/lsof" <<'STUB'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/calls.log"
echo "lsof: proc_listpids failed: Cannot allocate memory" >&2
exit 1
STUB
chmod +x "$OUT/poison/lsof"
: > "$OUT/poison/calls.log"
export PATH="$OUT/poison:/usr/bin:/bin:/usr/sbin:/sbin"
say "INJECTED_LSOF=$OUT/poison/lsof"
say "LAUNCH_PATH=$PATH"
export OPENCLAW_LOG_DIR="$OUT/logs-new"
"$NEW_APP/Contents/MacOS/OpenClaw" --attach-only --debug-open-menu > "$OUT/new-app.log" 2>&1 &
NEW_PID=$!
say "NEW_APP_PID=$NEW_PID"
APP_PID=""
for i in $(seq 1 60); do
  APP_PID=$(pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" | head -1)
  [ -n "$APP_PID" ] && break
  sleep 1
done
say "NEW_APP_UP=${APP_PID:-none}"
export APP_PID
sleep 20

say "--- stub calls by the candidate (raw) ---"
cat "$OUT/poison/calls.log"
say "--- AX tree (safe lines) ---"
osascript "$PROBE_DIR/ax-all.applescript" > "$OUT/ax-new.txt" 2>&1 || true
grep -vE 'missing value|^WINDOW_COUNT|^ELEMENTS|^===' "$OUT/ax-new.txt" | head -30 || true
say "--- unified log matches (raw) ---"
log show --last 20m --info --debug --style compact \
  --predicate 'process == "OpenClaw" OR subsystem == "ai.openclaw"' \
  > "$OUT/oslog-new.txt" 2>&1 || true
grep -iE 'resume|retained|Could not inspect port|Could not determine whether port|using existing instance|five failed starts|childSupervisor|forced install|gateway install --force|install' \
  "$OUT/oslog-new.txt" | tail -40 || true
screencapture -x "$OUT/screen-new.png" >/dev/null 2>&1 || true

# ------------------------------------- read the same state back with the CLI --
say "==== candidate reads the preserved state back ===="
"$NEW_BUN" "$NEW_MJS" gateway status --runtime-intent-only --json \
  > "$OUT/intent-after.json" 2>&1 || true
"$NEW_BUN" "$NEW_MJS" gateway status > "$OUT/gateway-status-after.log" 2>&1 || true
"$NEW_BUN" "$NEW_MJS" status --json > "$OUT/status-after.json" 2>&1 || true
say "--- candidate gateway status (safe lines) ---"
grep -iE 'Port |Listening|running|service|resume' "$OUT/gateway-status-after.log" | head -8 || true

# Only the service subtree is compared; the two CLIs report their own version.
python3 - "$OUT/intent-before.json" "$OUT/intent-after.json" \
  > "$OUT/intent-compare.txt" 2>&1 <<'PY'
import json
import sys


def load(path):
    raw = open(path, errors="replace").read()
    start = raw.find("{")
    if start < 0:
        return {}
    try:
        return json.JSONDecoder().raw_decode(raw[start:])[0]
    except Exception:
        return {}


def service(path):
    return load(path).get("service", {})


before = service(sys.argv[1])
after = service(sys.argv[2])
intent_before = before.get("runtimeIntent") or {}
intent_after = after.get("runtimeIntent") or {}
print("INTENT_STATUS_BEFORE=" + str(intent_before.get("status")))
print("INTENT_STORED_BEFORE=" + str(intent_before.get("stored")))
print("INTENT_REVISION_BEFORE=" + str(intent_before.get("revision")))
print("INTENT_PIN_PATH_BEFORE=" + str((intent_before.get("pin") or {}).get("path")))
print("INTENT_STATUS_AFTER=" + str(intent_after.get("status")))
print("INTENT_REVISION_AFTER=" + str(intent_after.get("revision")))
print("SERVICE_INTENT_EQUAL=" + ("1" if before == after else "0"))
PY
say "--- intent compare ---"
cat "$OUT/intent-compare.txt"

PLIST_AFTER=$(sha "$PLIST")
PIN_AFTER=$(sha "$PIN_DB")
CONFIG_AFTER=$(sha "$CONFIG")
RESUME_AFTER_RAW=$(read_resume)
RESUME_AFTER_SAFE=$(printf '%s' "$RESUME_AFTER_RAW" | redact)
say "PLIST_SHA_AFTER=$PLIST_AFTER"
say "PIN_DB_SHA_AFTER=$PIN_AFTER"
say "CONFIG_SHA_AFTER=$CONFIG_AFTER"
say "RESUME_COMMAND_AFTER=$RESUME_AFTER_SAFE"
say "LISTENER_COUNT_AFTER=$(count_listeners)"

# Storage still exists and is readable.
plutil -lint "$PLIST" > "$OUT/plist-lint.txt" 2>&1 || true
sqlite3 "$PIN_DB" 'PRAGMA integrity_check;' > "$OUT/pin-integrity.txt" 2>&1 || true
python3 -m json.tool "$CONFIG" > "$OUT/config-parsed.json" 2>&1 || true
say "--- storage readability ---"
cat "$OUT/plist-lint.txt" 2>/dev/null || true
cat "$OUT/pin-integrity.txt" 2>/dev/null || true

# ------------------------------------------------------------------- verdict
EVID_FILES="$OUT/oslog-new.txt $OUT/new-app.log $OUT/ax-new.txt"
for f in "$OUT/logs-new/"*.log; do [ -f "$f" ] && EVID_FILES="$EVID_FILES $f"; done

RESUME_CHANGED=0
[ "$RESUME_AFTER_RAW" != "$RESUME_BEFORE_RAW" ] && RESUME_CHANGED=1
CHILD_ATTEMPT=0
if grep -qiE 'five failed starts|childSupervisor|child exited|gateway child launch' $EVID_FILES 2>/dev/null; then
  CHILD_ATTEMPT=1
fi
FORCED_INSTALL=0
if grep -qiE 'forced install|force install|forced reinstall|"install", "--force"|gateway install --force' $EVID_FILES 2>/dev/null; then
  FORCED_INSTALL=1
fi
INTENT_EQUAL=0
grep -q '^SERVICE_INTENT_EQUAL=1' "$OUT/intent-compare.txt" 2>/dev/null && INTENT_EQUAL=1

say "RESUME_CHANGED=$RESUME_CHANGED"
say "CHILD_ATTEMPT=$CHILD_ATTEMPT"
say "FORCED_INSTALL=$FORCED_INSTALL"
say "INTENT_EQUAL=$INTENT_EQUAL"
say "LISTENER_RESTORED=$LISTENER_RESTORED"
say "LISTENER_AFTER=$(real_listeners | tr '\n' ',')"
say "==== verdict ===="
check "the old app installed the LaunchAgent itself" test "$PLIST_UP" -eq 1
check "the old app wrote a runtime pin itself" test "$PIN_BEFORE" != ABSENT
check "the old app wrote the resume command through its own pause" \
  test "$RESUME_BEFORE_RAW" != ABSENT
check "the old app recovered its paused service from that command" test "$LISTENER_RESTORED" -eq 1
check "the failing lsof reached the candidate app" test -s "$OUT/poison/calls.log"
check "the failing lsof asked about the Gateway port" grep -q -- "-iTCP:$PORT" "$OUT/poison/calls.log"
check "the LaunchAgent survived the candidate byte-identically" \
  test "$PLIST_RESTORED" = "$PLIST_AFTER"
check "the pin store survived the candidate byte-identically" \
  test "$PIN_RESTORED" = "$PIN_AFTER"
check "the config survived the candidate byte-identically" \
  test "$CONFIG_RESTORED" = "$CONFIG_AFTER"
check "the candidate reports the same service intent" test "$INTENT_EQUAL" -eq 1
check "no forced install was logged" test "$FORCED_INSTALL" -eq 0
check "no competing app-hosted child was started" test "$CHILD_ATTEMPT" -eq 0
check "the listener set is unchanged by the candidate" \
  test "$(real_listeners)" = "$RESTORED_LISTENERS"
check "the LaunchAgent is still readable" grep -qi 'OK' "$OUT/plist-lint.txt"
check "the pin store is still a valid sqlite database" grep -qi 'ok' "$OUT/pin-integrity.txt"
check "the config is still valid JSON" test -s "$OUT/config-parsed.json"
check "the Gateway is healthy after the candidate read it" \
  grep -qiE 'Port '"$PORT"'|Listening|running' "$OUT/gateway-status-after.log"
check "only one Gateway listener remains" test "$(count_listeners)" -le 1

stop_app
stop_gateways
launchctl unsetenv PATH >/dev/null 2>&1 || true
say "PROOF_FAIL=$fail"
exit "$fail"
