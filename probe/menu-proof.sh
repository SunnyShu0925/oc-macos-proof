#!/bin/bash
# Drive the shipped app's status menu and capture the open NSMenu popups.
#
# The status item opens the dashboard on a left click, so every stage starts
# the app with --debug-open-menu (a shipped debug flag that calls the same
# presentMenu path a right click uses) and reads the menu it puts on screen.
#
# Usage: menu-proof.sh   (run from the openclaw checkout)
set -u
P="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/shots
mkdir -p "$OUT"
export P OUT

APP_BUNDLE="${APP_BUNDLE:-$PWD/dist/OpenClaw.app}"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/OpenClaw"

relaunch() {
  pkill -f "$APP_EXEC" 2>/dev/null || true
  sleep 3
  open "$APP_BUNDLE" --args ${MENU_FLAGS:---attach-only --debug-open-menu}
  sleep 12
  APP_PID=$(pgrep -f "$APP_EXEC" | head -1 || true)
  export APP_PID
  echo "RELAUNCH app_pid=${APP_PID:-none} flags=${MENU_FLAGS:---attach-only --debug-open-menu}"
  ps -o args= -p "${APP_PID:-0}" 2>/dev/null || true
  swift "$P/menu-windows.swift" OpenClaw 0 2>&1 | head -12
}

drill() {
  local title="$1" click_off="$2" dest="$3"
  osascript "$P/status-menu-drill.applescript" "$title" "$click_off" 2>&1 | tee "$dest"
}

capture() {
  local stage="$1"
  swift "$P/menu-windows.swift" 2>&1 | tee "/tmp/popups-$stage.txt"
  local count
  count=$(grep -c '^POPUP id=' "/tmp/popups-$stage.txt" || true)
  echo "CAPTURE stage=$stage popups=$count"
  for id in $(grep -o 'POPUP id=[0-9]*' "/tmp/popups-$stage.txt" | cut -d= -f2); do
    local png="$OUT/$stage-$id.png"
    screencapture -x -o -l "$id" "$png"
    local rc=$?
    echo "SHOT stage=$stage id=$id exit=$rc bytes=$(stat -f%z "$png" 2>/dev/null || echo 0)"
    swift "$P/ocr-window.swift" "$png" > "/tmp/ocr-$stage-$id.txt" 2>&1
    echo "OCR stage=$stage id=$id :: $(tr '\n' '|' < "/tmp/ocr-$stage-$id.txt")"
    if [ -s "$png" ]; then
      local big="$OUT/$stage-$id-3x.png"
      cp "$png" "$big"
      sips --resampleWidth 720 "$big" >/dev/null 2>&1 || true
    fi
  done
  screencapture -x "$OUT/full-$stage.png" || true
}

# 1. Session inherits agents.defaults.thinkingDefault=high: the menu must not
#    claim "Off" when nothing is overridden.
relaunch
drill Thinking 0 /tmp/ax-thinking-fresh.txt
capture thinking-fresh

# 2. Choosing Off writes the explicit override through the shipping menu.
drill Thinking 1 /tmp/ax-thinking-click-off.txt
sleep 6

# 3. Restart so the reopened menu reflects the stored override.
relaunch
drill Thinking 0 /tmp/ax-thinking-off.txt
capture thinking-off

# 4. Verbose inherits verboseDefault=on and must not claim "Off" either.
relaunch
drill Verbose 0 /tmp/ax-verbose-fresh.txt
capture verbose-fresh

echo "MENU_PROOF_DONE"
