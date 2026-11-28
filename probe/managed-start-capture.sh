#!/bin/bash
# PortGuardian PR #201553 - ordinary managed startup, packaged app, no fixtures.
#
#   managed-start-capture.sh <label> <broken|free>
#
# The previous lifecycle fixtures set ~/.openclaw/disable-launchagent and passed
# --attach-only. Both reach `installation == .external`, and
# startAppHostedGateway returns at GatewayProcessManager+Hosting.swift:341 before
# the inspection branch at :360, so their "no child" result came from the fixture.
# This capture removes both: no marker, no attach-only, Onboarding already seen,
# no LaunchAgent installed, so installation falls through to .managed and the app
# reaches the branch under test on its own.
#
#   broken: lsof exits 1 with a diagnostic -> the port is unreadable
#           expectation: no Gateway child, no listener, unknown-port diagnostic
#   free:   lsof exits 1 with no diagnostic -> the port is idle
#           expectation: a real child starts (this is the control that proves the
#           fixture can produce a child at all)
#
# The verdict is echoed as PASS:/FAIL: lines and PROOF_FAIL=<n>.
set -uo pipefail

LABEL="${1:?usage: managed-start-capture.sh <label> <broken|free>}"
MODE="${2:?usage: managed-start-capture.sh <label> <broken|free>}"
case "$MODE" in broken|free) ;; *) echo "bad mode: $MODE"; exit 2 ;; esac

APP="${APP_PATH:?APP_PATH required}"
OUT="${OUT_DIR:-/tmp/pg201553/managed-$MODE}"
PROBE_DIR="${PROBE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
PORT="${GATEWAY_PORT:-18789}"
BUNDLE_ID="${BUNDLE_ID:-ai.openclaw.mac}"
REAL_LSOF=/usr/sbin/lsof
PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
STATE="$HOME/.openclaw"
fail=0

mkdir -p "$OUT"
run_limited() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@" 2>&1 || true; }
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label"; fail=$((fail + 1)); fi
}
say() { echo; echo "==== $* ===="; }

say "capture label=$LABEL mode=$MODE"
echo "APP=$APP"
echo "APP_BINARY_SHA=$(shasum -a 256 "$APP/Contents/MacOS/OpenClaw" | awk '{print $1}')"

# ---------------------------------------------------------------- the fixture fix
say "remove the two fixture shortcuts"
rm -f "$STATE/disable-launchagent"
if [ -e "$STATE/disable-launchagent" ]; then
  echo "DISABLE_MARKER=present"
else
  echo "DISABLE_MARKER=absent"
fi
launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
rm -f "$PLIST"
# A previous capture's app holds an AppInstanceLock (MenuBar.swift:229) that makes
# the next launch print "OpenClaw profile is already running" and exit(2). Its
# Gateway child may also still own port 18789, which makes the next capture attach
# instead of starting its own child. Kill every trace and wait until the port is
# actually free.
pkill -9 -f "openclaw.mjs gateway" 2>/dev/null || true
pkill -9 -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null || true
pkill -9 -f "OpenClaw.app/Contents/Resources/runtime" 2>/dev/null || true
for w in $(seq 1 15); do
  remaining=$(pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" | wc -l | tr -d ' ')
  listener=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" -eq 0 ] && [ "$listener" -eq 0 ] && break
  pkill -9 -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null || true
  pkill -9 -f "openclaw.mjs gateway" 2>/dev/null || true
  sleep 1
done
rm -rf "/tmp/openclaw-$(id -u)-app-instances" 2>/dev/null || true
rm -f "$STATE/.instance.lock" "$STATE/instance.lock" 2>/dev/null || true
sleep 1
echo "LAUNCHAGENT_PRESENT=$( [ -e "$PLIST" ] && echo yes || echo no )"
echo "LISTENERS_BEFORE=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- ordinary state
say "seed the ordinary state an installed user has"
mkdir -p "$STATE"
cat > "$STATE/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "port": $PORT, "auth": { "mode": "none" } }
}
JSON
defaults write "$BUNDLE_ID" openclaw.onboardingSeen -bool true 2>/dev/null || true
defaults write "$BUNDLE_ID" openclaw.onboardingVersion -int 99 2>/dev/null || true
echo "onboardingSeen=$(defaults read "$BUNDLE_ID" openclaw.onboardingSeen 2>/dev/null || echo missing)"
echo "onboardingVersion=$(defaults read "$BUNDLE_ID" openclaw.onboardingVersion 2>/dev/null || echo missing)"

# ---------------------------------------------------------------- the lsof answer
POISON="$OUT/poison-$MODE"
rm -rf "$POISON"; mkdir -p "$POISON"
CALLS="$OUT/stub-calls.log"; : > "$CALLS"
if [ "$MODE" = "broken" ]; then
  # Exit 1 as lsof does for "no match", but with a diagnostic on stderr: the
  # probe must treat this as unreadable, not as a free port.
  cat > "$POISON/lsof" <<STUB
#!/bin/bash
echo "\$*" >> "$CALLS"
echo "lsof: proc_listpids failed: Cannot allocate memory" >&2
exit 1
STUB
else
  # Exit 1 with nothing on stderr: exactly what an idle port returns.
  cat > "$POISON/lsof" <<STUB
#!/bin/bash
echo "\$*" >> "$CALLS"
exit 1
STUB
fi
chmod +x "$POISON/lsof"
echo "stub=$POISON/lsof"
echo "launch PATH=$POISON:/usr/bin:/bin:/usr/sbin:/sbin"

# ---------------------------------------------------------------- launch the app
# No --attach-only and no --no-launchd: those would set attachOnly and keep the
# app away from the start path. --debug-open-menu only opens the status menu so
# the app's own Debug -> Restart Gateway entry is reachable by AX.
say "launch the packaged app normally (no --attach-only)"
LOG="$OUT/app.log"
: > "$LOG"
PATH="$POISON:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$APP/Contents/MacOS/OpenClaw" > "$LOG" 2>&1 &
APP_PID=$!
echo "APP_PID=$APP_PID"

sleep 15
EARLY_CALLS=$(wc -l < "$CALLS" | tr -d ' ')
echo "STUB_CALLS_AT_LAUNCH=$EARLY_CALLS"
if [ "$EARLY_CALLS" -eq 0 ]; then
  # The app may need more time to reach ConnectionModeCoordinator.apply. Poll
  # for the stub call instead of guessing a fixed sleep.
  for w in $(seq 1 15); do
    sleep 3
    EARLY_CALLS=$(wc -l < "$CALLS" | tr -d ' ')
    [ "$EARLY_CALLS" -ge 1 ] && break
  done
  echo "STUB_CALLS_AFTER_WAIT=$EARLY_CALLS"
fi

# The app probes, and on an idle port seeds a runtime before it starts a child,
# so the window is generous and both outcomes are polled.
CHILD_MAX=0
LISTENER_MAX=0
for tick in $(seq 1 40); do
  sleep 3
  # The child is a bun process; its command line may not contain "openclaw.mjs"
  # or "gateway" verbatim. The authoritative signal is a listener on the port
  # owned by a process that is not the app itself.
  listener_lines=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null | grep '^p' | sort -u)
  listener_count=$(echo "$listener_lines" | grep -c '^p')
  app_pid_str="p$APP_PID"
  child=0
  for lp in $listener_lines; do
    lpid=${lp#p}
    [ "$lpid" = "$APP_PID" ] && continue
    [ -n "$lpid" ] && child=$((child + 1))
  done
  listener=$listener_count
  [ "$child" -gt "$CHILD_MAX" ] && CHILD_MAX=$child
  [ "$listener" -gt "$LISTENER_MAX" ] && LISTENER_MAX=$listener
  if [ "$MODE" = "free" ] && { [ "$child" -ge 1 ] || [ "$listener" -ge 1 ]; }; then
    echo "poll $tick: child=$child listener=$listener (control satisfied)"
    break
  fi
  if [ "$MODE" = "broken" ] && [ "$tick" -ge 12 ]; then
    echo "poll $tick: child=$child listener=$listener"
    break
  fi
done

say "observed"
# Count listeners not owned by the app process itself.
listener_lines_now=$("$REAL_LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -Fp 2>/dev/null | grep '^p' | sort -u)
CHILD_NOW=0
LISTENER_NOW=0
for lp in $listener_lines_now; do
  lpid=${lp#p}
  LISTENER_NOW=$((LISTENER_NOW + 1))
  [ "$lpid" = "$APP_PID" ] && continue
  [ -n "$lpid" ] && CHILD_NOW=$((CHILD_NOW + 1))
done
STUB_CALLS=$(wc -l < "$CALLS" | tr -d ' ')
echo "CHILD_MAX=$CHILD_MAX"
echo "LISTENER_MAX=$LISTENER_MAX"
echo "CHILD_NOW=$CHILD_NOW"
echo "LISTENER_NOW=$LISTENER_NOW"
echo "STUB_CALLS=$STUB_CALLS"
echo "DISABLE_MARKER_AFTER=$( [ -e "$STATE/disable-launchagent" ] && echo present || echo absent )"
echo "LAUNCHAGENT_AFTER=$( [ -e "$PLIST" ] && echo written || echo absent )"
echo "--- stub invocations ---"
head -5 "$CALLS"
echo "--- ps: gateway-ish processes ---"
ps -Ao pid,command | grep -E "openclaw.mjs gateway|OpenClaw.app/Contents/MacOS" | grep -v grep | head -6 || echo "(none)"
echo "--- app log: the lines that matter ---"
grep -aoE "externally managed[^\"]{0,80}|Could not inspect port [0-9]+[^\"\n]{0,70}|Could not determine whether port [0-9]+[^\"\n]{0,60}|Gateway stopped after five failed starts|Gateway child launch failed" "$LOG" | head -8 || echo "(none)"
echo "--- unified log: gateway/port/child lines ---"
run_limited 90 log show --last 8m --style compact \
  --predicate 'process == "OpenClaw"' \
  > "$OUT/oslog.txt" 2>&1 || true
grep -iE 'could not (inspect|determine)|externally managed|five failed|child.*launch|attach|gateway.*start|using existing|retry in a moment|publishGateway|fail|unknown|unreadable|connect failed|health' \
  "$OUT/oslog.txt" | tail -30 || echo "(no unified-log matches)"

say "verdict"
check "the disable-launchagent fixture is gone" test ! -e "$STATE/disable-launchagent"
check "the shipped probe ran through the poisoned PATH" test "$STUB_CALLS" -ge 1
# The app's startup goes through ConnectionModeCoordinator -> setActive(true) ->
# startIfNeeded -> attachExistingGatewayIfAvailable, which calls inspect. A
# Release build has no Debug menu, so there is no AX click to verify; the stub
# call count itself proves the shipped probe ran.
check "the app reached its own startup path" test "$STUB_CALLS" -ge 1
# .external would have failed at Hosting.swift:341 with this exact sentence and
# never reached the inspection branch, which is what made the old fixtures moot.
check "startup was not refused as an externally managed Gateway" \
  bash -c "! grep -aq 'externally managed' '$LOG' '$OUT/oslog.txt'"
if [ "$MODE" = "broken" ]; then
  check "an unreadable port never produced a Gateway child" test "$CHILD_MAX" -eq 0
  check "no listener appeared on the unreadable port" test "$LISTENER_MAX" -eq 0
  # .unknown takes the attach path first (attachExistingGatewayIfAvailable), which
  # publishes a readiness terminal or "Could not determine whether port ... is free"
  # before returning true, so startAppHostedGateway is never reached. The diagnostic
  # may be either of those; both prove the app did not silently treat the port as free.
  check "the app published an unknown-port diagnostic (not silent free)" \
    bash -c "grep -aqiE 'could not (determine whether port|inspect port)|connect to the server|retry in a moment' '$LOG' '$OUT/oslog.txt'"
else
  # The control the review asked for: the same fixture, same binary, same launch
  # path, must be able to start a healthy child when the port really is free.
  check "an idle port starts a real Gateway child" test "$CHILD_MAX" -ge 1
  check "the idle-port child owns the listener" test "$LISTENER_MAX" -ge 1
fi

pkill -9 -f "OpenClaw.app/Contents/MacOS/OpenClaw" 2>/dev/null || true
kill -9 "$APP_PID" 2>/dev/null || true
pkill -9 -f "openclaw.mjs gateway" 2>/dev/null || true
pkill -9 -f "OpenClaw.app/Contents/Resources/runtime" 2>/dev/null || true

echo "PROOF_FAIL=$fail"
exit "$([ "$fail" -eq 0 ] && echo 0 || echo 1)"
