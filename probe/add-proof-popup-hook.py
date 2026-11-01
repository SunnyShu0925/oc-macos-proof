"""Add a proof-only menu opener to the packaged app.

The shipped `--debug-open-menu` flag calls `presentMenu()`, which sets
`statusItem.menu` and then `button.performClick(nil)`. In the headless runner
that path ends without putting an NSMenu on screen, and a manually popped menu
is not reachable through the status item's accessibility children. The harness
therefore pops the real menus with `NSMenu.popUp` and records the state AppKit
is about to draw.

Trigger: write a command into /tmp/openclaw-proof-popup-request:

  root          pop the whole status menu
  Thinking      pop the session row's Thinking submenu
  Verbose       pop the session row's Verbose submenu
  Thinking-off  run the "Off" item of that submenu (applies the override)
  diagnose      dump control-channel state, session rows and the store error

Submenu commands rewrite /tmp/openclaw-proof-menu-state.txt with the titles and
states of the submenu items, so the capture can assert what was on screen.
`diagnose` writes /tmp/openclaw-proof-diagnostics.txt.

Only this opener is harness code: the menu, the session rows and the
Thinking/Verbose items are the shipping implementation. Idempotent; fails
loudly when the anchor is not found.
"""

import pathlib
import sys

path = pathlib.Path("apps/macos/Sources/OpenClaw/StatusMenuController.swift")
source = path.read_text()

if "OPENCLAW_PROOF_POPUP_HOOK" in source:
    print("proof popup hook already present")
    sys.exit(0)

ANCHOR = """            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.presentMenu()
            }
        }
"""

body = pathlib.Path(__file__).resolve().with_name("proof-hook.swift").read_text()
indented = "\n".join(("        " + line) if line.strip() else "" for line in body.splitlines())
HOOK = ANCHOR + "\n" + indented + "\n"

if source.count(ANCHOR) != 1:
    sys.exit("proof hook anchor matched %d times, expected 1" % source.count(ANCHOR))

path.write_text(source.replace(ANCHOR, HOOK))
print("proof popup hook installed")
