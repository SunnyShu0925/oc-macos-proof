import AppKit

// Minimal status-bar app that mirrors the shipped menu shape: a status item
// whose menu contains a "Thinking" submenu with one checked item, plus a
// normal window used as a capture control.
//
// With --open-menu it forces the root menu on screen with NSMenu.popUp, so the
// probe does not depend on accessibility clicks or on the app being frontmost.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let statusItem = NSStatusBar.system.statusItem(withLength: 90)
statusItem.button?.title = "OCPROBE"

let thinkingMenu = NSMenu()
thinkingMenu.showsStateColumn = true
for (title, on) in [("Off", false), ("Minimal", false), ("Low", false), ("Medium", false), ("High", true)] {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.state = on ? .on : .off
    thinkingMenu.addItem(item)
}

let rootMenu = NSMenu()
let thinkingItem = NSMenuItem(title: "Thinking", action: nil, keyEquivalent: "")
thinkingItem.submenu = thinkingMenu
rootMenu.addItem(thinkingItem)

let verboseMenu = NSMenu()
verboseMenu.showsStateColumn = true
for title in ["Off", "On"] {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.state = title == "Off" ? .on : .off
    verboseMenu.addItem(item)
}
let verboseItem = NSMenuItem(title: "Verbose", action: nil, keyEquivalent: "")
verboseItem.submenu = verboseMenu
rootMenu.addItem(verboseItem)

statusItem.menu = rootMenu

let window = NSWindow(
    contentRect: NSRect(x: 120, y: 120, width: 520, height: 220),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "Menu Probe Window"
let label = NSTextField(labelWithString: "PROBE WINDOW 24680")
label.font = NSFont.systemFont(ofSize: 28, weight: .bold)
label.frame = NSRect(x: 30, y: 80, width: 460, height: 60)
window.contentView?.addSubview(label)
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()

func log(_ line: String) {
    print(line)
    if let data = (line + "\n").data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/appwin.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

func dumpWindows(_ tag: String) {
    log("APPWIN_DUMP \(tag) count=\(NSApp.windows.count) active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)")
    for w in NSApp.windows {
        log("APPWIN num=\(w.windowNumber) class=\(type(of: w)) visible=\(w.isVisible) frame=\(NSStringFromRect(w.frame))")
    }
}

if CommandLine.arguments.contains("--open-submenu") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        log("BEFORE_SUBMENU_POPUP")
        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            dumpWindows("submenu-tracking")
        }
        RunLoop.main.add(timer, forMode: .common)
        // Screen coordinates because the view is nil.
        thinkingMenu.popUp(positioning: thinkingItem, at: NSPoint(x: 700, y: 520), in: nil)
        log("AFTER_SUBMENU_POPUP")
        timer.invalidate()
    }
}

if CommandLine.arguments.contains("--open-menu") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        log("BEFORE_POPUP")
        NSApp.activate(ignoringOtherApps: true)
        dumpWindows("before-popup")
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            dumpWindows("tracking")
        }
        RunLoop.main.add(timer, forMode: .common)
        // Blocks in menu tracking until the menu is dismissed.
        rootMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: statusItem.button)
        log("AFTER_POPUP")
        dumpWindows("after-popup")
        timer.invalidate()
    }
}

log("MENU_PROBE_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
dumpWindows("startup")
DispatchQueue.global().asyncAfter(deadline: .now() + 900) { exit(0) }
app.run()
