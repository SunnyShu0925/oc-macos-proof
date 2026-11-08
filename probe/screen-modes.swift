import AppKit
import CoreGraphics

// Report the display geometry the proof runs on: the pixel size drives how tall
// the Agent Events window can get, which decides whether both runs can share one
// frame without scrolling.
let main = CGMainDisplayID()
let pixels = "\(CGDisplayPixelsWide(main))x\(CGDisplayPixelsHigh(main))"
let bounds = CGDisplayBounds(main)
if let screen = NSScreen.main {
    let frame = screen.frame
    let visible = screen.visibleFrame
    print("PIXELS=\(pixels)")
    print("BOUNDS=\(Int(bounds.width))x\(Int(bounds.height))")
    print("SCREEN_FRAME=\(Int(frame.width))x\(Int(frame.height))")
    print("VISIBLE_FRAME=\(Int(visible.width))x\(Int(visible.height)) scale=\(screen.backingScaleFactor)")
} else {
    print("PIXELS=\(pixels) BOUNDS=\(Int(bounds.width))x\(Int(bounds.height)) NO_NSCREEN")
}
for screen in NSScreen.screens {
    print("SCREEN name=\(screen.localizedName) frame=\(Int(screen.frame.width))x\(Int(screen.frame.height))")
}
