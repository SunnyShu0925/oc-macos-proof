import CoreGraphics
import Foundation

// Scroll the focused window under a screen point so the proof can bring the
// older run into the same viewport as the newer one. Accessibility scrollbar
// writes are unreliable for SwiftUI ScrollView; a wheel event is what a person
// actually does.
guard CommandLine.arguments.count >= 4,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]),
      let ticks = Int(CommandLine.arguments[3])
else {
    FileHandle.standardError.write(Data("usage: scroll-wheel.swift <x> <y> <ticks>\n".utf8))
    exit(2)
}
let point = CGPoint(x: x, y: y)
if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
    move.post(tap: .cghidEventTap)
}
usleep(200_000)
for _ in 0 ..< ticks {
    if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0) {
        event.location = point
        event.post(tap: .cghidEventTap)
    }
    usleep(30_000)
}
print("WHEEL_SCROLLED ticks=\(ticks) at=\(Int(x)),\(Int(y))")
