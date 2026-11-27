#!/bin/bash
# Drive the packaged OpenClaw.app to its onboarding connection page and capture
# what the local-Gateway row says.
#
#   onboarding-capture.sh <label> <broken|healthy>
#
# "broken" puts an lsof on the app's PATH that fails the way proc_listpids does,
# so the shipped PortGuardian probe cannot answer. "healthy" leaves the real lsof
# in place as the control. Both runs are the same binary, so the only difference
# in the captured copy is the probe outcome.
set -uo pipefail

LABEL="${1:?label required}"
MODE="${2:?mode required}"
APP="${APP_PATH:?APP_PATH required}"
OUT="${OUT_DIR:?OUT_DIR required}"
PROBE_DIR="${GITHUB_WORKSPACE:-.}/proofrepo/probe"
BUNDLE_ID="ai.openclaw.mac"
PORT="${GATEWAY_PORT:-18789}"

mkdir -p "$OUT"
POISON="$OUT/poison-$LABEL"
mkdir -p "$POISON"
CALLS="$POISON/calls.log"
: > "$CALLS"

echo "==== capture label=$LABEL mode=$MODE ===="
echo "app=$APP"
echo "port=$PORT"
echo "APP_BINARY_SHA=$(shasum -a 256 "$APP/Contents/MacOS/OpenClaw" 2>/dev/null | awk '{print $1}')"

# PortGuardian treats `lsof` exit 1 with no diagnostic on stderr as "nothing is
# listening", and exit 1 with a diagnostic as a scan it could not trust. Those are
# the two answers this probe replays, so the same binary is driven down both paths.
case "$MODE" in
  broken)
    cat > "$POISON/lsof" <<'STUB'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/calls.log"
echo "lsof: proc_listpids failed: Cannot allocate memory" >&2
exit 1
STUB
    ;;
  free)
    cat > "$POISON/lsof" <<'STUB'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/calls.log"
# Nothing matched: this is exactly what lsof does for an idle port.
exit 1
STUB
    ;;
  real)
    ;;
  *)
    echo "unknown mode $MODE"
    exit 2
    ;;
esac

if [ "$MODE" != "real" ]; then
  chmod +x "$POISON/lsof"
  # The app resolves lsof through /usr/bin/env, so PATH decides which lsof runs.
  export PATH="$POISON:/usr/bin:/bin:/usr/sbin:/sbin"
  echo "injected stub lsof at $POISON/lsof ($MODE)"
else
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  echo "using the real lsof"
fi
echo "launch PATH=$PATH"

# A clean install: no stored config and no prior onboarding, so the app opens
# onboarding on its own. The launch-agent marker keeps startup from installing.
rm -f "$HOME/.openclaw/openclaw.json"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" openclaw.onboardingSeen -bool false
defaults write "$BUNDLE_ID" openclaw.onboardingVersion -int 0
mkdir -p "$HOME/.openclaw"
touch "$HOME/.openclaw/disable-launchagent"
pkill -f "OpenClaw.app/Contents/MacOS/OpenClaw" >/dev/null 2>&1 || true
sleep 2

# `open` forwards the shell's environment but LaunchServices normalizes PATH, so the
# app is exec'd directly: Bundle.main is still the .app, and the poisoned PATH is
# the one the probe actually sees.
"$APP/Contents/MacOS/OpenClaw" --attach-only > "$OUT/app-$LABEL.log" 2>&1 &
LAUNCHED_PID=$!
echo "started app binary pid=$LAUNCHED_PID"

APP_PID=""
for i in $(seq 1 90); do
  APP_PID=$(pgrep -f "OpenClaw.app/Contents/MacOS/OpenClaw" | head -1)
  if [ -n "$APP_PID" ]; then
    echo "app up after ${i}s pid=$APP_PID"
    break
  fi
  sleep 1
done
if [ -z "$APP_PID" ]; then
  echo "APP_NOT_RUNNING"
  exit 1
fi

echo "--- what the app inherited ---"
ps eww -p "$APP_PID" 2>/dev/null | tr ' ' '\n' | grep -E '^PATH=' || echo "PATH_NOT_VISIBLE"

sleep 10
echo "--- welcome state ---"
osascript "$PROBE_DIR/ax-all.applescript" > "$OUT/ax-$LABEL-welcome.txt" 2>&1 || true
grep -E "WINDOW_COUNT|ELEMENTS=|Welcome to OpenClaw" "$OUT/ax-$LABEL-welcome.txt" | head -10
screencapture -x "$OUT/screen-$LABEL-welcome.png" || true

echo "--- advancing to the connection page ---"
# SwiftUI buttons carry no AX title here, but Next is the window's default action,
# so Return advances the same way it does for a user.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" || true
sleep 2
osascript -e 'tell application "System Events" to key code 36' || true
# refreshLocalGatewayProbe uses the same 5 s probe deadline, so allow it to settle.
sleep 14

echo "--- connection state ---"
osascript "$PROBE_DIR/ax-all.applescript" > "$OUT/ax-$LABEL-connection.txt" 2>&1 || true
grep -E "WINDOW_COUNT|ELEMENTS=|Where should your assistant run" "$OUT/ax-$LABEL-connection.txt" | head -10
echo "--- AX text sample ---"
grep -vE "missing value|^WINDOW_COUNT|^ELEMENTS|^===" "$OUT/ax-$LABEL-connection.txt" | head -40
screencapture -x "$OUT/screen-$LABEL-connection.png" || true

echo "--- local Gateway row copy ---"
grep -E "Installs and starts automatically|Could not check whether port|is free|port $PORT" \
  "$OUT/ax-$LABEL-connection.txt" | head -10 || echo "NO_ROW_COPY"

# The subtitle sits inside a SwiftUI button, which the AX tree reports as "missing
# value", so OCR of the window is the record. It is sampled repeatedly because the
# probe runs on its own deadline and the row updates when it lands.
final_ocr="$OUT/ocr-$LABEL-connection.txt"
normalized="$OUT/ocr-$LABEL-normalized.txt"
: > "$final_ocr"
: > "$normalized"
# Vision occasionally substitutes look-alike letters ("automatıcally"), so every
# match below runs against a lowercase ASCII fold of the same text.
fold_ocr() { iconv -f UTF-8 -t ASCII//TRANSLIT "$1" 2>/dev/null || cat "$1"; }
COPY_PATTERN="installs and starts|could not check whether port|already in use|existing gateway detected"
for poll in $(seq 1 10); do
  WID=$(swift "$PROBE_DIR/window-id.swift" OpenClaw 2>/dev/null | head -1)
  shot="$OUT/window-$LABEL-connection.png"
  if [ -n "${WID:-}" ]; then
    screencapture -x -o -l "$WID" "$shot" || true
  else
    shot="$OUT/screen-$LABEL-connection.png"
  fi
  [ -s "$shot" ] || continue
  swift "$PROBE_DIR/ocr-window.swift" "$shot" > "$final_ocr" 2>&1 || true
  fold_ocr "$final_ocr" | tr 'A-Z' 'a-z' > "$normalized"
  match=$(grep -E "$COPY_PATTERN" "$normalized" | head -1)
  echo "poll $poll ($(basename "$shot")): ${match:-<no row copy yet>}"
  if [ -n "$match" ]; then
    break
  fi
  sleep 3
done
echo "--- OCR lines: $(wc -l < "$final_ocr" | tr -d ' ') ---"
head -15 "$final_ocr" || true
echo "--- folded text ---"
head -15 "$normalized" || true

echo "--- stub invocations by the app ---"
echo "STUB_CALLS=$(wc -l < "$CALLS" | tr -d ' ')"
cat "$CALLS" || true

echo "--- app log tail ---"
log show --last 3m --style compact --predicate "process == \"OpenClaw\"" 2>/dev/null \
  | grep -iE "port|inspect|lsof|gateway" | tail -20 || true

pkill -f "OpenClaw.app/Contents/MacOS/OpenClaw" >/dev/null 2>&1 || true
sleep 2
launchctl unsetenv PATH >/dev/null 2>&1 || true
echo "==== capture $LABEL done ===="
