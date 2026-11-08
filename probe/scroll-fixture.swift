import AppKit
import SwiftUI

// Minimal SwiftUI ScrollView fixture: the probe uses it to learn how this
// runner's scroll wheel events reach a SwiftUI ScrollView before spending a full
// packaging run on the shipped app.

struct Fixture: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(0 ..< 60, id: \.self) { index in
                    Text("ROW-\(index)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(8)
        }
    }
}

func findScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for sub in view.subviews {
        if let scroll = findScrollView(sub) { return scroll }
    }
    return nil
}

let accessory = CommandLine.arguments.contains("--accessory")
let app = NSApplication.shared
app.setActivationPolicy(accessory ? .accessory : .regular)

let window = NSWindow(
    contentRect: NSRect(x: 40, y: 40, width: 420, height: 340),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false)
window.title = "Scroll Fixture"
window.contentView = NSHostingView(rootView: Fixture())
window.makeKeyAndOrderFront(nil)
if !accessory {
    app.activate(ignoringOtherApps: true)
}

let offsetPath = "/tmp/offset.txt"
FileManager.default.createFile(atPath: offsetPath, contents: nil)

func snapshot(_ note: String) {
    guard let scroll = findScrollView(window.contentView!) else { return }
    let offset = scroll.contentView.bounds.origin.y
    let doc = scroll.documentView?.bounds.height ?? -1
    let clip = scroll.contentView.bounds.height
    let line = "\(note) offset=\(Int(offset)) doc=\(Int(doc)) clip=\(Int(clip)) key=\(window.isKeyWindow)\n"
    if let handle = FileHandle(forWritingAtPath: offsetPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    }
}

Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    snapshot("beat")
}

app.run()
