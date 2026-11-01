#!/bin/bash
# Capture the shipping status menu and its Thinking/Verbose submenus.
#
# The harness hook (probe/add-proof-popup-hook.py) pops the real NSMenu objects
# that StatusMenuSessions builds and records their item states, because the
# headless runner cannot open the status item menu with a pointer and a
# manually popped menu is invisible to the accessibility tree.
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
STATE=/tmp/openclaw-proof-menu-state.txt

start_app() {
  pkill -f "$APP_EXEC" 2>/dev/null || true
  sleep 3
  touch "$ENABLED"
  rm -f "$REQUEST" "$STATE"
  open "$APP_BUNDLE" --args --attach-only
  sleep 12
  APP_PID=$(pgrep -f "$APP_EXEC" | head -1 || true)
  export APP_PID
  echo "START app_pid=${APP_PID:-none}"
}

command() {
  local name="$1"
  rm -f "$REQUEST"
  printf '%s' "$name" > "$REQUEST"
  sleep 3
}

capture() {
  local stage="$1"
  cp "$STATE" "/tmp/state-$stage.txt" 2>/dev/null || : > "/tmp/state-$stage.txt"
  echo "STATE stage=$stage :: $(tr '\n' '|' < "/tmp/state-$stage.txt")"
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

close_menu() {
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
  sleep 2
}

start_app

# 0. Whole status menu: shows the session row this capture works with.
command root
capture root
close_menu

# 1. Inherited Thinking (agents.defaults.thinkingDefault=high): no "Off" mark.
command Thinking
capture thinking-fresh
close_menu

# 2. Choosing Off through the shipping menu item applies the override.
command Thinking-off
sleep 5

# 3. The reopened submenu must show the stored override.
command Thinking
capture thinking-off
close_menu

# 4. Inherited Verbose (agents.defaults.verboseDefault=on): no "Off" mark.
command Verbose
capture verbose-fresh
close_menu

echo "MENU_PROOF_DONE"
