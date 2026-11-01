#!/bin/bash
# Drive the shipped app's status menu and capture the open NSMenu popups.
#
# The status item opens the dashboard on a left click and `performClick` does
# not put the menu on screen in a headless runner, so the harness installs a
# request-file opener that pops the same shipping menu (probe/add-proof-popup-
# hook.py). Everything below the popup — the session rows, the Thinking/Verbose
# submenus and their check marks — is the code under test.
#
# Usage: menu-proof.sh   (run from the openclaw checkout)
set -u
P="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/shots
mkdir -p "$OUT"
export P OUT

APP_BUNDLE="${APP_BUNDLE:-$PWD/dist/OpenClaw.app}"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/OpenClaw"
REQUEST=/tmp/openclaw-proof-popup-request
ENABLED=/tmp/openclaw-proof-popup-enabled

start_app() {
  pkill -f "$APP_EXEC" 2>/dev/null || true
  sleep 3
  touch "$ENABLED"
  rm -f "$REQUEST"
  open "$APP_BUNDLE" --args --attach-only
  sleep 12
  APP_PID=$(pgrep -f "$APP_EXEC" | head -1 || true)
  export APP_PID
  echo "START app_pid=${APP_PID:-none}"
}

open_menu() {
  rm -f "$REQUEST"
  touch "$REQUEST"
  sleep 3
}

close_menu() {
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
  sleep 2
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

start_app

# 1. Inherited Thinking (default high): the menu must not claim "Off".
open_menu
drill Thinking 0 /tmp/ax-thinking-fresh.txt
capture thinking-fresh

# 2. Reopen the same session submenu: the update path must agree.
close_menu
open_menu
drill Thinking 0 /tmp/ax-thinking-reuse.txt
capture thinking-reuse

# 3. Choosing Off writes the explicit override through the shipping menu.
drill Thinking 1 /tmp/ax-thinking-click-off.txt
sleep 6

# 4. The reopened menu must show the stored override.
open_menu
drill Thinking 0 /tmp/ax-thinking-off.txt
capture thinking-off

# 5. Inherited Verbose (default on): no "Off" check either.
close_menu
open_menu
drill Verbose 0 /tmp/ax-verbose-fresh.txt
capture verbose-fresh

echo "MENU_PROOF_DONE"
