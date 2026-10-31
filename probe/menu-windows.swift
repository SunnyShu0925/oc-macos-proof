import CoreGraphics
import Foundation

// Print the popup menu windows owned by the running OpenClaw app so the proof
// can capture the on-screen NSMenu with `screencapture -l`.
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
var found = 0
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("OpenClaw") else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    guard layer >= 100 else { continue }
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let id = w[kCGWindowNumber as String] as? Int ?? -1
    let x = bounds["X"] ?? 0
    let y = bounds["Y"] ?? 0
    let width = bounds["Width"] ?? 0
    let height = bounds["Height"] ?? 0
    if id < 0 { continue }
    found += 1
    print("POPUP id=\(id) layer=\(layer) rect=\(x),\(y),\(width),\(height)")
}
print("POPUP_COUNT=\(found)")
