import AppKit

// Minimal status-bar app that mirrors the shipped menu shape: a status item
// whose menu contains a "Thinking" submenu with one checked item, plus a
// normal window used as a capture control.

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

print("MENU_PROBE_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
DispatchQueue.global().asyncAfter(deadline: .now() + 600) { exit(0) }
app.run()
