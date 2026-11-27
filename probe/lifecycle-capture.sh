#!/bin/bash
# PortGuardian PR #201553 - lifecycle head/base contrast.
#
#   lifecycle-capture.sh <label> <head|base> [with-listener|no-listener]
#
# A real Gateway is already listening on 18789 (started from the *packaged*
# app's bundled runtime, config auth none). A failing lsof stub is placed at the
# front of the app's PATH - it records every call and never emits a fake p/c
# line. The packaged candidate/base app is then exec'd directly (not via
# `open`, which normalizes PATH) and Debug -> Restart Gateway is clicked through
# AX. The real /usr/sbin/lsof plus ps/pgrep compare the listener before/after.
#
#   head: attach / unknown-port copy, exactly one listener, no child spawned
#   base: a competing child start - a new listener, or a start attempt in the
#         child/app log ("Gateway stopped after five failed starts", etc.)
#
# Env: APP_PATH, OUT_DIR, PROBE_DIR, OPENCLAW_DIR (pnpm fallback), BUNDLE_ID,
#      GATEWAY_PORT. Verdict is echoed as PASS:/FAIL: lines and PROOF_FAIL=<n>.
set -uo pipefail

LABEL="${1:?usage: lifecycle-capture.sh <label> <head|base>}"
MODE="${2:?usage: lifecycle-capture.sh <label> <head|base>}"
SCENARIO="${3:-with-listener}"
case "$MODE" in head|base) ;; *) echo "bad mode: $MODE"; exit 2 ;; esac
case "$SCENARIO" in with-listener|no-listener) ;; *) echo "bad scenario: $SCENARIO"; exit 2 ;; esac

APP="${APP_PATH:?APP_PATH required}"
OUT="${OUT_DIR:-/tmp/pg201553/lifecycle-$MODE}"
PROBE_DIR="${PROBE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
BUNDLE_ID="${BUNDLE_ID:-ai.openclaw.mac}"
PORT="${GATEWAY_PORT:-18789}"
REAL_LSOF=/usr/sbin/lsof
RT="$APP/Contents/Resources/runtime"
MJS="$RT/lib/node_modules/openclaw/openclaw.mjs"
BUN="$RT/bin/bun"

mkdir -p "$OUT/logs" "$OUT/poison"
CALLS="$OUT/poison/calls.log"
STATUS="$OUT/verdict.log"
: > "$CALLS"
: > "$STATUS"

say() { echo "$@" | tee -a "$STATUS"; }

fail=0
check() {
  local label="$1"; shift
  if "$@"; then say "PASS: $label"; else say "FAIL: $label"; fail=1; fi
}

# The real binary, always outside the poisoned PATH. -Fp prints only p<pid>.
app_pids() { pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null | tr '\n' ' '; }
stop_app() {
  local pids
  pids=$(app_pids)
  if [ -n "$pids" ]; then kill -9 $pids >/dev/null 2>&1 || true; fi
  for _ in $(seq 1 20); do
    [ -z "$(app_pids)" ] && break
    sleep 1
  done
  rm -f "/tmp/openclaw-$(id -u)-app-instances/ai.openclaw.mac.lock" >/dev/null 2>&1 || true
}
real_listeners() {
  "$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null \
    | sed -n 's/^p//p' | sort -u
}
listener_count() { real_listeners | grep -c . || true; }
gateway_run_procs() {
  ps -axww -o pid=,command= 2>/dev/null \
    | grep -F "$MJS gateway run" | grep -v 'grep -F' | grep -c . || true
}
app_procs() { pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" | grep -c . || true; }
stop_gateways() { pkill -9 -f "$MJS gateway run" >/dev/null 2>&1 || true; }

# Keep a stuck Accessibility query or unified-log dump from consuming the whole
# job. Every bounded command is still run directly; only its wall clock is capped.
run_limited() {
  local seconds="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$seconds"; kill -9 "$cmd_pid" >/dev/null 2>&1 || true ) &
  local watchdog=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" >/dev/null 2>&1 || true
  return "$rc"
}

say "==== lifecycle label=$LABEL mode=$MODE scenario=$SCENARIO ===="
say "APP=$APP"
say "APP_BINARY_SHA=$(shasum -a 256 "$APP/Contents/MacOS/OpenClaw" 2>/dev/null | awk '{print $1}')"
say "PORT=$PORT"
say "HOSTED_MACOS=$(sw_vers -productVersion 2>/dev/null)"

# ---------------------------------------------------------------- clean slate
stop_app
stop_gateways
sleep 2
rm -f "$HOME/.openclaw/openclaw.json"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
mkdir -p "$HOME/.openclaw"
# Keep the app from installing a launchd job behind the captured run's back.
touch "$HOME/.openclaw/disable-launchagent"
cat > "$HOME/.openclaw/openclaw.json" <<JSON
{ "gateway": { "mode": "local", "port": $PORT, "auth": { "mode": "none" } } }
JSON

# ------------------------------------------- optionally start one real Gateway
GW_UP=0
if [ "$SCENARIO" = with-listener ]; then
  if [ -x "$BUN" ] && [ -f "$MJS" ]; then
    say "REAL_GATEWAY=runtime bundled in the packaged app"
    ( cd "$HOME" && nohup "$BUN" "$MJS" gateway run > "$OUT/real-gateway.log" 2>&1 & echo $! > "$OUT/real-gateway.pid" )
  else
    say "REAL_GATEWAY=pnpm openclaw gateway run (from OPENCLAW_DIR)"
    ( cd "${OPENCLAW_DIR:-.}" && nohup pnpm openclaw gateway run > "$OUT/real-gateway.log" 2>&1 & echo $! > "$OUT/real-gateway.pid" )
  fi
  for i in $(seq 1 120); do
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then GW_UP=1; break; fi
    sleep 1
  done
else
  say "REAL_GATEWAY=none (no-listener scenario)"
  i=0
fi
say "REAL_GATEWAY_UP=$GW_UP after ${i}s"
say "--- real gateway log (raw tail) ---"
tail -12 "$OUT/real-gateway.log" 2>/dev/null | sed -E 's/(token|apiKey|api_key|secret|password)[^,}]*/\1=<redacted>/Ig' || true
if [ "$SCENARIO" = with-listener ] && [ "$GW_UP" -ne 1 ]; then
  say "FAIL: a real Gateway never listened on $PORT"
  say "PROOF_FAIL=1"
  exit 1
fi

# ------------------------------------------------------------- before snapshot
BEFORE_PIDS=$(real_listeners)
BEFORE_COUNT=$(listener_count)
BEFORE_GW_PROCS=$(gateway_run_procs)
BEFORE_APP_PROCS=$(app_procs)
say "LISTENER_PIDS_BEFORE=$(echo "$BEFORE_PIDS" | tr '\n' ',')"
say "LISTENER_COUNT_BEFORE=$BEFORE_COUNT"
say "GATEWAY_RUN_PROCS_BEFORE=$BEFORE_GW_PROCS"
say "APP_PROCS_BEFORE=$BEFORE_APP_PROCS"
for pid in $BEFORE_PIDS; do ps -p "$pid" -o pid=,command= >> "$OUT/listeners-before.ps" 2>/dev/null; done

# -------------------------------------------------- poisoned lsof on app PATH
cat > "$OUT/poison/lsof" <<'STUB'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/calls.log"
echo "lsof: proc_listpids failed: Cannot allocate memory" >&2
exit 1
STUB
chmod +x "$OUT/poison/lsof"
export PATH="$OUT/poison:/usr/bin:/bin:/usr/sbin:/sbin"
say "INJECTED_LSOF=$OUT/poison/lsof"
say "LAUNCH_PATH=$PATH"

# --------------------------------------------------- launch the app directly
defaults write "$BUNDLE_ID" openclaw.debugPaneEnabled -bool true
defaults write "$BUNDLE_ID" openclaw.onboardingSeen -bool true
defaults write "$BUNDLE_ID" openclaw.onboardingVersion -int 8
# Redirect the gateway/app log dir so a child's start attempt is captured.
export OPENCLAW_LOG_DIR="$OUT/logs"
mkdir -p "$OPENCLAW_LOG_DIR"
"$APP/Contents/MacOS/OpenClaw" --attach-only --debug-open-menu > "$OUT/app.log" 2>&1 &
LAUNCHED_PID=$!
say "LAUNCHED_PID=$LAUNCHED_PID"
APP_PID=""
for i in $(seq 1 60); do
  APP_PID=$(pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" | head -1)
  [ -n "$APP_PID" ] && break
  sleep 1
done
say "APP_UP_PID=${APP_PID:-none}"
export APP_PID
sleep 8
say "--- inherited PATH of the app ---"
ps eww -p "$APP_PID" 2>/dev/null | tr ' ' '\n' | grep -E '^PATH=' || echo "PATH_NOT_VISIBLE"

say "--- AX tree before restart ---"
run_limited 90 osascript "$PROBE_DIR/ax-all.applescript" > "$OUT/ax-before.txt" 2>&1 || true
grep -vE 'missing value|^WINDOW_COUNT|^ELEMENTS|^===' "$OUT/ax-before.txt" | head -20 || true

# ------------------------------------ AX click Debug -> Restart Gateway (real)
say "--- AX click Debug -> Restart Gateway ---"
run_limited 120 osascript "$PROBE_DIR/restart-gateway.applescript" > "$OUT/menu.log" 2>&1 || true
cat "$OUT/menu.log"

# The attach readiness probe can take up to 6.5s and a failed child may retry.
for i in $(seq 1 30); do
  sleep 1
  NOW=$(real_listeners)
  if [ "$i" -ge 12 ] && [ "$NOW" != "$BEFORE_PIDS" ]; then break; fi
done
say "SETTLE_SECONDS=$i"

# -------------------------------------------------------------- after snapshot
AFTER_PIDS=$(real_listeners)
AFTER_COUNT=$(listener_count)
AFTER_GW_PROCS=$(gateway_run_procs)
AFTER_APP_PROCS=$(app_procs)
say "LISTENER_PIDS_AFTER=$(echo "$AFTER_PIDS" | tr '\n' ',')"
say "LISTENER_COUNT_AFTER=$AFTER_COUNT"
say "GATEWAY_RUN_PROCS_AFTER=$AFTER_GW_PROCS"
say "APP_PROCS_AFTER=$AFTER_APP_PROCS"
for pid in $AFTER_PIDS; do ps -p "$pid" -o pid=,command= >> "$OUT/listeners-after.ps" 2>/dev/null; done

say "--- stub calls by the app (raw) ---"
cat "$CALLS"

say "--- AX tree after restart ---"
run_limited 90 osascript "$PROBE_DIR/ax-all.applescript" > "$OUT/ax-after.txt" 2>&1 || true
grep -vE 'missing value|^WINDOW_COUNT|^ELEMENTS|^===' "$OUT/ax-after.txt" | head -40 || true

say "--- unified log matches (raw) ---"
run_limited 120 log show --last 10m --style compact \
  --predicate 'process == "OpenClaw" AND (eventMessage CONTAINS[c] "gateway" OR eventMessage CONTAINS[c] "attach" OR eventMessage CONTAINS[c] "port" OR eventMessage CONTAINS[c] "child")' \
  > "$OUT/oslog.txt" 2>&1 || true
grep -iE 'using existing instance|Could not inspect port|Could not determine whether port|retry in a moment|five failed starts|childSupervisor|child exited|gateway child launch|attach' \
  "$OUT/oslog.txt" | tail -40 || true

say "--- gateway/app log files (raw tail) ---"
for f in "$OUT/logs/"*.log "$OUT/app.log"; do
  [ -f "$f" ] || continue
  say "=== $f ==="
  tail -40 "$f"
done
screencapture -x "$OUT/screen-$LABEL.png" >/dev/null 2>&1 || true

# ------------------------------------------------------------------- verdict
EVID_FILES="$OUT/oslog.txt $OUT/app.log $OUT/ax-after.txt $OUT/menu.log"
for f in "$OUT/logs/"*.log; do [ -f "$f" ] && EVID_FILES="$EVID_FILES $f"; done

CHILD_ATTEMPT=0
# Only a child-supervisor log in the redirected OPENCLAW_LOG_DIR or an explicit
# child-launch record proves the app spawned a gateway; a "Listening" status in
# the AX dump or unified log does not.
for f in "$OUT/logs/"*.log; do
  [ -s "$f" ] || continue
  if grep -qiE 'listen|bind|EADDRINUSE|address already in use|gateway child launch' "$f"; then
    CHILD_ATTEMPT=1
  fi
done
if grep -qiE 'five failed starts|childSupervisor|child exited|gateway child launch' \
  "$OUT/oslog.txt" "$OUT/app.log" 2>/dev/null; then
  CHILD_ATTEMPT=1
fi
ATTACH_COPY=0
if grep -qiE 'using existing instance|using existing gateway|Could not determine whether port|Could not inspect port|retry in a moment|attachedExisting|unknown-port|Could not check whether port|Failed: Could not' $EVID_FILES 2>/dev/null; then
  ATTACH_COPY=1
fi

say "CHILD_ATTEMPT=$CHILD_ATTEMPT"
say "ATTACH_COPY=$ATTACH_COPY"
say "==== verdict ($MODE) ===="
check "the app consulted the failing lsof" test -s "$CALLS"
check "the failing lsof saw the gateway port" grep -q -- "-iTCP:$PORT" "$CALLS"
check "Debug -> Restart Gateway was clicked" grep -q 'CLICKED_RESTART_GATEWAY' "$OUT/menu.log"

if [ "$SCENARIO" = with-listener ]; then
  if [ "$MODE" = "head" ]; then
    check "the real listener set is unchanged" test "$AFTER_PIDS" = "$BEFORE_PIDS"
    check "there is still exactly one Gateway listener" test "$AFTER_COUNT" -eq 1
    check "no extra Gateway run process appeared" test "$AFTER_GW_PROCS" -le "$BEFORE_GW_PROCS"
    check "no competing app-hosted child was started" test "$CHILD_ATTEMPT" -eq 0
    check "the app showed attach or unknown-port handling" test "$ATTACH_COPY" -eq 1
  else
    COMPETED=0
    if [ "$AFTER_PIDS" != "$BEFORE_PIDS" ] || [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then COMPETED=1; fi
    if [ "$AFTER_GW_PROCS" -gt "$BEFORE_GW_PROCS" ]; then COMPETED=1; fi
    if [ "$CHILD_ATTEMPT" -eq 1 ]; then COMPETED=1; fi
    say "LISTENER_CHANGED=$([ "$AFTER_PIDS" != "$BEFORE_PIDS" ] && echo 1 || echo 0)"
    check "base attempted a competing child start" test "$COMPETED" -eq 1
  fi
elif [ "$MODE" = "head" ]; then
  # An unreadable idle port must stay undecided: no child may claim it.
  check "the port stayed empty" test "$AFTER_COUNT" -eq 0
  check "no extra Gateway run process appeared" test "$AFTER_GW_PROCS" -le "$BEFORE_GW_PROCS"
  check "no app-hosted child was started" test "$CHILD_ATTEMPT" -eq 0
  check "the app showed unknown-port handling" test "$ATTACH_COPY" -eq 1
else
  # Base folds the failed probe into "free", so it starts a child on that port.
  CHILD_STARTED=0
  [ "$AFTER_COUNT" -ge 1 ] && CHILD_STARTED=1
  [ "$AFTER_GW_PROCS" -gt "$BEFORE_GW_PROCS" ] && CHILD_STARTED=1
  [ "$CHILD_ATTEMPT" -eq 1 ] && CHILD_STARTED=1
  say "CHILD_STARTED=$CHILD_STARTED"
  check "base started a child on the unreadable idle port" test "$CHILD_STARTED" -eq 1
fi

stop_app
stop_gateways
launchctl unsetenv PATH >/dev/null 2>&1 || true
say "PROOF_FAIL=$fail"
exit "$fail"
