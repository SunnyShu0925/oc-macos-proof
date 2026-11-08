import CoreGraphics
import Foundation

// Print the id and bounds of the first window whose title contains the needle.
let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Agent Events"
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for window in list {
    let name = window[kCGWindowName as String] as? String ?? ""
    guard name.contains(needle) else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let id = window[kCGWindowNumber as String] ?? -1
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    print("WID=\(id)")
    print("RECT=\(bounds["X"] ?? 0),\(bounds["Y"] ?? 0),\(bounds["Width"] ?? 0),\(bounds["Height"] ?? 0)")
    print("OWNER=\(owner) NAME=\(name)")
    exit(0)
}
print("NO_WINDOW \(needle)")
exit(1)
