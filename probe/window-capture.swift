import CoreGraphics
import Foundation

// Print the on-screen windows owned by the running OpenClaw app, one per line,
// so the proof can capture the shipped Agent Events window by id or bounds.
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
var found = 0
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("OpenClaw") else { continue }
    found += 1
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let name = w[kCGWindowName as String] as? String ?? ""
    let id = w[kCGWindowNumber as String] ?? -1
    let x = bounds["X"] ?? 0
    let y = bounds["Y"] ?? 0
    let width = bounds["Width"] ?? 0
    let height = bounds["Height"] ?? 0
    print("WINDOW owner=\(owner) name=\(name) id=\(id) bounds=\(x),\(y),\(width),\(height)")
    if name == "Agent Events" {
        print("AGENT_EVENTS_WID=\(id)")
        print("AGENT_EVENTS_RECT=\(x),\(y),\(width),\(height)")
    }
}
if found == 0 {
    print("NO_OPENCLAW_WINDOWS")
}
