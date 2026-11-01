import CoreGraphics
import Foundation

let ownerFilter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "OpenClaw"
let minLayer = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 100) : 100
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
var found = 0
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains(ownerFilter) else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    guard layer >= minLayer else { continue }
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
