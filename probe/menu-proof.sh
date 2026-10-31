#!/bin/bash
# Drive the shipped app's status menu and capture the open NSMenu popups.
# Usage: menu-proof.sh
set -u
P="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/shots
mkdir -p "$OUT"
export P OUT

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

drill Thinking 0 /tmp/ax-thinking-fresh.txt
sleep 1
capture thinking-fresh

drill Thinking 0 /tmp/ax-thinking-reuse.txt
sleep 1
capture thinking-reuse

# Clicking Off applies the explicit override through the shipping UI.
drill Thinking 1 /tmp/ax-thinking-click-off.txt
sleep 6
drill Thinking 0 /tmp/ax-thinking-off.txt
sleep 1
capture thinking-off

drill Verbose 0 /tmp/ax-verbose-fresh.txt
sleep 1
capture verbose-fresh

echo "MENU_PROOF_DONE"
