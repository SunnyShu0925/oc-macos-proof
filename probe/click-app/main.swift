import AppKit

final class ClickProbe: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var monitor: Any?

    func log(_ line: String) {
        let path = "/tmp/click.log"
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.menu.addItem(NSMenuItem(title: "CLICK MENU ITEM ONE", action: nil, keyEquivalent: ""))
        self.menu.addItem(NSMenuItem(title: "CLICK MENU ITEM TWO", action: nil, keyEquivalent: ""))
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem.button?.title = "CP"
        self.statusItem.button?.target = self
        self.statusItem.button?.action = #selector(self.clicked(_:))
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let button = self.statusItem?.button, let window = button.window,
                  event.windowNumber == window.windowNumber
            else { return event }
            let point = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(point) else { return event }
            let isRight = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            self.log("MONITOR type=\(event.type.rawValue) control=\(event.modifierFlags.contains(.control)) right=\(isRight)")
            if isRight {
                self.presentMenu()
            } else {
                self.log("LEFT_WOULD_OPEN_DASHBOARD")
            }
            return nil
        }
        self.log("READY pid=\(ProcessInfo.processInfo.processIdentifier)")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let window = self.statusItem.button?.window, let screen = window.screen else { return }
            let frame = window.frame
            let centerX = frame.origin.x + frame.width / 2
            let centerY = screen.frame.height - (frame.origin.y + frame.height / 2)
            self.log("BUTTON_CENTER \(Int(centerX)) \(Int(centerY)) frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))")
        }

    }

    @objc func clicked(_ sender: Any?) {
        self.log("ACTION_FIRED")
    }

    func presentMenu() {
        self.log("PRESENT_MENU")
        self.statusItem.button?.performClick(nil)
        self.log("PRESENT_MENU_RETURNED")
    }
}

let app = NSApplication.shared
let delegate = ClickProbe()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
