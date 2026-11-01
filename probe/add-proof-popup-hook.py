"""Add a proof-only menu opener to the packaged app.

The shipped `--debug-open-menu` flag calls `presentMenu()`, which sets
`statusItem.menu` and then `button.performClick(nil)`. In the headless runner
that path ends without putting an NSMenu on screen, so the capture uses
`NSMenu.popUp` anchored in the status item button instead — the same call the
probe app has already proven to produce a capturable popup. The menu contents
and the Thinking/Verbose construction code stay untouched.

The request-file trigger keeps the opener repeatable within one app run so the
capture can exercise the "reopen an existing submenu" path as well.

Idempotent; fails loudly when the anchor is not found.
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

HOOK = ANCHOR + """
        // OPENCLAW_PROOF_POPUP_HOOK: proof harness only, not part of the fix.
        // Pops the shipping menu on a request file so the capture can open it
        // without a pointer and reopen it to exercise the reuse path.
        if FileManager.default.fileExists(atPath: "/tmp/openclaw-proof-popup-enabled") {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                let request = "/tmp/openclaw-proof-popup-request"
                guard FileManager.default.fileExists(atPath: request) else { return }
                try? FileManager.default.removeItem(atPath: request)
                guard let self, let button = self.statusItem?.button else { return }
                self.statusItem?.menu = self.menu
                self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
                self.statusItem?.menu = nil
            }
        }
"""

if source.count(ANCHOR) != 1:
    sys.exit("proof hook anchor matched %d times, expected 1" % source.count(ANCHOR))

path.write_text(source.replace(ANCHOR, HOOK))
print("proof popup hook installed")
