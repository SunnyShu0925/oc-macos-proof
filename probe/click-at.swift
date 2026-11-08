import CoreGraphics
import Foundation

// Click a screen point so the window under it becomes key before scrolling.
guard CommandLine.arguments.count >= 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2])
else {
    FileHandle.standardError.write(Data("usage: click-at.swift <x> <y>\n".utf8))
    exit(2)
}
let point = CGPoint(x: x, y: y)
if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
    move.post(tap: .cghidEventTap)
}
usleep(150_000)
if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
    down.post(tap: .cghidEventTap)
}
usleep(80_000)
if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
    up.post(tap: .cghidEventTap)
}
print("CLICKED \(Int(x)),\(Int(y))")
