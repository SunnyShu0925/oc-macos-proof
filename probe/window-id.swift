import CoreGraphics
import Foundation

// Print the window number of the frontmost on-screen window owned by an app whose
// owner name contains the argument, so a capture can target the window alone.
let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "OpenClaw"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for info in list {
    guard let owner = info[kCGWindowOwnerName as String] as? String, owner.contains(needle) else { continue }
    guard let number = info[kCGWindowNumber as String] as? Int else { continue }
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    guard layer == 0 else { continue }
    print(number)
    exit(0)
}
exit(1)
