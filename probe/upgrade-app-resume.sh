#!/bin/bash
# PortGuardian PR #201553 - real old-build -> candidate upgrade / data-model proof.
#
# The old build's shipped CLI installs the managed Gateway (LaunchAgent + runtime
# pin). The OLD APP ITSELF then pauses through its real cold-start path, which
# writes gatewayNodeResumeCommand and removes the plist. The candidate cold-starts
# with a failing lsof on its PATH and must consume that app-written resume record,
# restore the service, and keep the port healthy instead of forcing an install.
# The script never hand-writes a plist, a pin or a resume record.
#
# Env: OLD_APP_PATH, NEW_APP_PATH, OUT_DIR, PROBE_DIR, BUNDLE_ID, GATEWAY_PORT.
# Verdict is echoed as PASS:/FAIL: lines and PROOF_FAIL=<n>. Values that can carry
# a token / IP / phone / endpoint pass through redact() before echo.
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
LOCK_DIR="/tmp/openclaw-$(id -u)-app-instances"

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

redact() {
  sed -E \
    -e 's/((token|apiKey|api_key|secret|password|authorization)[^,}]*)/\1=<redacted>/Ig' \
    -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' \
    -e 's/1[3-9][0-9]{9}/<phone>/g' \
    -e 's#wss?://[^", ]+#<endpoint>#g'
}

app_pids() { pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null | tr '\n' ' '; }
stop_app() {
  local pids
  pids=$(app_pids)
  if [ -n "$pids" ]; then kill -9 $pids >/dev/null 2>&1 || true; fi
  for _ in $(seq 1 20); do
    [ -z "$(app_pids)" ] && break
    sleep 1
  done
  # The lock is an flock on a file path; with every opener gone it is safe to
  # remove the stale inode before the next cold start.
  rm -f "$LOCK_DIR/ai.openclaw.mac.lock" >/dev/null 2>&1 || true
}
stop_gateways() {
  pkill -9 -f "$OLD_MJS gateway run" >/dev/null 2>&1 || true
  pkill -9 -f "$NEW_MJS gateway run" >/dev/null 2>&1 || true
}
real_listeners() {
  "$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null \
    | sed -n 's/^p//p' | sort -u
}
count_listeners() { real_listeners | grep -c . || true; }
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

# ------------------------------------------------------------ clean slate
stop_app
stop_gateways
sleep 2
rm -f "$PLIST" "$PIN_DB" "$PIN_DB-wal" "$PIN_DB-shm" "$CONFIG" \
  "$HOME/.openclaw/disable-launchagent"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
mkdir -p "$(dirname "$PLIST")" "$(dirname "$PIN_DB")" "$HOME/.openclaw"
cat > "$CONFIG" <<JSON
{ "gateway": { "mode": "local", "port": $PORT, "auth": { "mode": "none" } } }
JSON
defaults write "$BUNDLE_ID" gatewayHosting -string service
defaults write "$BUNDLE_ID" openclaw.onboardingSeen -bool true
defaults write "$BUNDLE_ID" openclaw.onboardingVersion -int 8
defaults write "$BUNDLE_ID" openclaw.pauseEnabled -bool false
defaults write "$BUNDLE_ID" openclaw.debugPaneEnabled -bool true
CONFIG_BEFORE=$(sha "$CONFIG")
say "CONFIG_SHA_BEFORE=$CONFIG_BEFORE"

# ---------------------------- old build installs its own managed service ----
say "==== old build's shipped CLI installs the managed service ===="
"$OLD_BUN" "$OLD_MJS" gateway install --runtime bun --runtime-path "$OLD_BUN" \
  > "$OUT/install-old.log" 2>&1
OLD_INSTALL_RC=$?
say "OLD_INSTALL_RC=$OLD_INSTALL_RC"
tail -15 "$OUT/install-old.log" | sed -E 's/(token|apiKey|api_key|secret|password)[^,}]*/\1=<redacted>/Ig' || true

PLIST_UP=0
for _ in $(seq 1 120); do
  if [ -f "$PLIST" ]; then PLIST_UP=1; break; fi
  sleep 1
done
say "PLIST_WRITTEN_BY_OLD_BUILD=$PLIST_UP"
for _ in $(seq 1 90); do
  [ "$(count_listeners)" -ge 1 ] && break
  sleep 1
done
say "OLD_SERVICE_LISTENING=$(count_listeners)"

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

# ----------------------------- old app pauses through its real cold start ---
say "==== old app pauses itself (writes the resume command) ===="
stop_app
sleep 2
defaults write "$BUNDLE_ID" openclaw.pauseEnabled -bool true
export OPENCLAW_LOG_DIR="$OUT/logs-pause"
"$OLD_APP/Contents/MacOS/OpenClaw" --debug-open-menu > "$OUT/old-app-pause.log" 2>&1 &
OLD_PAUSE_PID=$!
say "OLD_PAUSE_PID=$OLD_PAUSE_PID"

RESUME_BEFORE_RAW=ABSENT
for _ in $(seq 1 120); do
  R=$(read_resume)
  if [ "$R" != ABSENT ]; then RESUME_BEFORE_RAW="$R"; break; fi
  sleep 1
done
say "RESUME_WRITTEN_BY_OLD_PAUSE=$([ "$RESUME_BEFORE_RAW" != ABSENT ] && echo yes || echo no)"
say "RESUME_COMMAND_BEFORE=$(printf '%s' "$RESUME_BEFORE_RAW" | redact)"
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
sleep 2

# ------------------ candidate cold start consumes the app-written resume ----
say "==== candidate cold start: unreadable port + app-written Resume ===="
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
defaults write "$BUNDLE_ID" openclaw.pauseEnabled -bool false
export OPENCLAW_LOG_DIR="$OUT/logs-new"
"$NEW_APP/Contents/MacOS/OpenClaw" --debug-open-menu > "$OUT/new-app.log" 2>&1 &
NEW_PID=$!
say "NEW_APP_PID=$NEW_PID"
APP_PID=""
for _ in $(seq 1 60); do
  APP_PID=$(pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" | head -1)
  [ -n "$APP_PID" ] && break
  sleep 1
done
say "NEW_APP_UP=${APP_PID:-none}"
export APP_PID

RESUME_CHANGED=0
for _ in $(seq 1 90); do
  R_AFTER=$(read_resume)
  if [ "$R_AFTER" != "$RESUME_BEFORE_RAW" ]; then RESUME_CHANGED=1; break; fi
  sleep 1
done
for _ in $(seq 1 90); do
  [ "$(count_listeners)" -ge 1 ] && break
  sleep 1
done
sleep 10

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

say "==== candidate reads the preserved state back ===="
"$NEW_BUN" "$NEW_MJS" gateway status --runtime-intent-only --json \
  > "$OUT/intent-after.json" 2>&1 || true
"$NEW_BUN" "$NEW_MJS" gateway status > "$OUT/gateway-status-after.log" 2>&1 || true
"$NEW_BUN" "$NEW_MJS" status --json > "$OUT/status-after.json" 2>&1 || true
say "--- candidate gateway status (safe lines) ---"
grep -iE 'Port |Listening|running|service|resume' "$OUT/gateway-status-after.log" | head -8 || true

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


def intent(path):
    return (load(path).get("service") or {}).get("runtimeIntent") or {}


before = intent(sys.argv[1])
after = intent(sys.argv[2])
print("INTENT_STATUS_BEFORE=" + str(before.get("status")))
print("INTENT_STORED_BEFORE=" + str(before.get("stored")))
print("INTENT_PIN_PATH_BEFORE=" + str((before.get("pin") or {}).get("path")))
print("INTENT_STATUS_AFTER=" + str(after.get("status")))
print("INTENT_STORED_AFTER=" + str(after.get("stored")))
print("INTENT_PIN_PATH_AFTER=" + str((after.get("pin") or {}).get("path")))
print("SERVICE_INTENT_USABLE=" + ("1" if before.get("status") == "known"
                                   and after.get("status") == "known"
                                   and (after.get("pin") or {}).get("path") else "0"))
PY
say "--- intent compare ---"
cat "$OUT/intent-compare.txt"

PLIST_AFTER=$(sha "$PLIST")
PIN_AFTER=$(sha "$PIN_DB")
CONFIG_AFTER=$(sha "$CONFIG")
RESUME_AFTER_RAW=$(read_resume)
say "PLIST_SHA_AFTER=$PLIST_AFTER"
say "PIN_DB_SHA_AFTER=$PIN_AFTER"
say "CONFIG_SHA_AFTER=$CONFIG_AFTER"
say "RESUME_COMMAND_AFTER=$(printf '%s' "$RESUME_AFTER_RAW" | redact)"
say "LISTENER_COUNT_AFTER=$(count_listeners)"
say "LISTENER_PIDS_AFTER=$(real_listeners | tr '\n' ',')"

plutil -lint "$PLIST" > "$OUT/plist-lint.txt" 2>&1 || true
sqlite3 "$PIN_DB" 'PRAGMA integrity_check;' > "$OUT/pin-integrity.txt" 2>&1 || true
python3 -m json.tool "$CONFIG" > "$OUT/config-parsed.json" 2>&1 || true

# ---------------------------------------------------------------- verdict
EVID_FILES="$OUT/oslog-new.txt $OUT/new-app.log $OUT/ax-new.txt"
for f in "$OUT/logs-new/"*.log; do [ -f "$f" ] && EVID_FILES="$EVID_FILES $f"; done

CHILD_ATTEMPT=0
if grep -qiE 'five failed starts|childSupervisor|child exited|gateway child launch' $EVID_FILES 2>/dev/null; then
  CHILD_ATTEMPT=1
fi
FORCED_INSTALL=0
if grep -qiE 'forced install|force install|forced reinstall|"install", "--force"|gateway install --force' $EVID_FILES 2>/dev/null; then
  FORCED_INSTALL=1
fi
INTENT_USABLE=0
grep -q '^SERVICE_INTENT_USABLE=1' "$OUT/intent-compare.txt" 2>/dev/null && INTENT_USABLE=1

say "RESUME_CHANGED=$RESUME_CHANGED"
say "CHILD_ATTEMPT=$CHILD_ATTEMPT"
say "FORCED_INSTALL=$FORCED_INSTALL"
say "INTENT_USABLE=$INTENT_USABLE"
say "LISTENER_RESTORED=$(count_listeners)"
say "==== verdict ===="
check "the old build's CLI installed the LaunchAgent itself" test "$PLIST_UP" -eq 1
check "the old build's CLI wrote a runtime pin itself" test "$PIN_BEFORE" != ABSENT
check "the old app wrote the resume command through its own pause" \
  test "$RESUME_BEFORE_RAW" != ABSENT
check "the old app paused the service (plist removed)" test "$PLIST_PAUSED" = ABSENT
check "the failing lsof reached the candidate app" test -s "$OUT/poison/calls.log"
check "the failing lsof asked about the Gateway port" grep -q -- "-iTCP:$PORT" "$OUT/poison/calls.log"
check "the candidate consumed or cleared the app-written resume command" \
  test "$RESUME_CHANGED" -eq 1
check "the candidate restored the LaunchAgent from the resume command" \
  test "$PLIST_AFTER" != ABSENT
check "the config survived byte-identically" test "$CONFIG_BEFORE" = "$CONFIG_AFTER"
check "the candidate reports a known service intent with a runtime pin" test "$INTENT_USABLE" -eq 1
check "no forced install was logged" test "$FORCED_INSTALL" -eq 0
check "no competing app-hosted child was started" test "$CHILD_ATTEMPT" -eq 0
check "the LaunchAgent is still readable" grep -qi 'OK' "$OUT/plist-lint.txt"
check "the pin store is still a valid sqlite database" grep -qi 'ok' "$OUT/pin-integrity.txt"
check "the config is still valid JSON" test -s "$OUT/config-parsed.json"
check "the Gateway is healthy after the candidate resumed it" \
  grep -qiE 'Port '"$PORT"'|Listening|running' "$OUT/gateway-status-after.log"
check "only one Gateway listener remains" test "$(count_listeners)" -le 1

stop_app
stop_gateways
launchctl unsetenv PATH >/dev/null 2>&1 || true
say "PROOF_FAIL=$fail"
exit "$fail"
