// Proof harness only, not part of the fix. Inserted into
// StatusMenuController.scheduleDebugMenuOpen by probe/add-proof-popup-hook.py.
if FileManager.default.fileExists(atPath: "/tmp/openclaw-proof-popup-enabled") {
    func recordProofMenuState(_ menu: NSMenu) {
        var out = ""
        for item in menu.items {
            out += "ITEM name=\(item.title) state=\(item.state.rawValue)\n"
        }
        try? out.write(toFile: "/tmp/openclaw-proof-menu-state.txt", atomically: true, encoding: .utf8)
    }

    func proofFindSubmenu(_ title: String) -> NSMenu? {
        for item in self.menu.items {
            if let submenu = item.submenu,
               submenu.items.contains(where: { $0.title == title }) {
                return submenu
            }
        }
        return nil
    }

    func dumpProofDiagnostics() {
        var out = "CONTROL \(String(describing: self.controlChannel.state))\n"
        let rows = self.sessions.rows
        out += "ROWS \(rows.count)\n"
        for row in rows {
            out += "ROW key=\(row.key) label=\(row.label)\n"
        }
        out += "ERROR \(self.sessions.errorText ?? "none")\n"
        out += "CONNECTION \(String(describing: self.state.connectionMode))\n"
        try? out.write(
            toFile: "/tmp/openclaw-proof-diagnostics.txt",
            atomically: true,
            encoding: .utf8)
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

            if command == "diagnose" {
                // Synchronous dump only: opening the menu is what triggers the
                // refresh, so the capture asks for a dump after it closes.
                dumpProofDiagnostics()
                return
            }
            if command == "Thinking" || command == "Verbose" {
                // Session rows load asynchronously; leave the menu closed when
                // the submenu is not built yet so the capture can retry.
                guard let submenu = proofFindSubmenu(command) else { return }
                self.statusItem?.menu = nil
                recordProofMenuState(submenu)
                submenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
                return
            }
            if command.hasSuffix("-off"),
               let submenu = proofFindSubmenu(String(command.dropLast(4))),
               let index = submenu.items.firstIndex(where: { $0.title == "Off" }) {
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
