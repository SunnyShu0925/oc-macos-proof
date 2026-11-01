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

Every command rewrites /tmp/openclaw-proof-menu-state.txt with the titles and
states of the submenu items, so the capture can assert what was on screen.

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

HOOK = ANCHOR + """
        // OPENCLAW_PROOF_POPUP_HOOK: proof harness only, not part of the fix.
        if FileManager.default.fileExists(atPath: "/tmp/openclaw-proof-popup-enabled") {
            func recordProofMenuState(_ menu: NSMenu) {
                var out = ""
                for item in menu.items {
                    out += "ITEM name=\\(item.title) state=\\(item.state.rawValue)\\n"
                }
                try? out.write(toFile: "/tmp/openclaw-proof-menu-state.txt", atomically: true, encoding: .utf8)
            }
            func proofFindSubmenu(_ title: String) -> NSMenu? {
                for item in self.menu.items {
                    if let submenu = item.submenu,
                       submenu.items.contains(where: { $0.title == title })
                    {
                        return submenu
                    }
                }
                return nil
            }
            func pollProofMenu() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    defer { pollProofMenu() }
                    let request = "/tmp/openclaw-proof-popup-request"
                    guard let raw = try? String(contentsOfFile: request, encoding: .utf8) else { return }
                    try? FileManager.default.removeItem(atPath: request)
                    let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let button = self.statusItem?.button else { return }
                    if command == "Thinking" || command == "Verbose" {
                        // The session rows load asynchronously; leave the menu
                        // closed when the submenu is not built yet so the
                        // capture can retry instead of showing the root menu.
                        guard let submenu = proofFindSubmenu(command) else { return }
                        self.statusItem?.menu = nil
                        recordProofMenuState(submenu)
                        submenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
                        return
                    }
                    if command.hasSuffix("-off"),
                       let submenu = proofFindSubmenu(String(command.dropLast(4))),
                       let index = submenu.items.firstIndex(where: { $0.title == "Off" })
                    {
                        submenu.performActionForItem(at: index)
                        recordProofMenuState(submenu)
                        return
                    }
                    self.statusItem?.menu = self.menu
                    self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
                    self.statusItem?.menu = nil
                }
            }
            pollProofMenu()
        }
"""

if source.count(ANCHOR) != 1:
    sys.exit("proof hook anchor matched %d times, expected 1" % source.count(ANCHOR))

path.write_text(source.replace(ANCHOR, HOOK))
print("proof popup hook installed")
