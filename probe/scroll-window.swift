import CoreGraphics
import Foundation

// Usage: scroll-window <x> <y> <ticks>  (positive = up, negative = down)
let args = CommandLine.arguments
guard args.count >= 4, let x = Double(args[1]), let y = Double(args[2]), let ticks = Int(args[3]) else {
    FileHandle.standardError.write(Data("usage: scroll-window <x> <y> <ticks>\n".utf8))
    exit(2)
}
let point = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(250_000)
let step = ticks > 0 ? 1 : -1
for _ in 0..<abs(ticks) {
    if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(step * 3), wheel2: 0) {
        event.location = point
        event.post(tap: .cghidEventTap)
    }
    usleep(60_000)
}
print("SCROLLED ticks=\(ticks) at \(Int(x)),\(Int(y))")
