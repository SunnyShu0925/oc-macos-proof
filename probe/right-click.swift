import CoreGraphics
import Foundation

// Post a real right-click at the given screen coordinates (top-left origin).
guard CommandLine.arguments.count >= 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2])
else {
    FileHandle.standardError.write(Data("usage: right-click.swift <x> <y>\n".utf8))
    exit(2)
}

let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
for type in [CGEventType.rightMouseDown, CGEventType.rightMouseUp] {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .right) else {
        FileHandle.standardError.write(Data("cannot create event\n".utf8))
        exit(3)
    }
    event.post(tap: .cghidEventTap)
    usleep(60_000)
}
print("POSTED_RIGHT_CLICK \(Int(x)),\(Int(y))")
