import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OpenClaw

// Proof probe for openclaw PR #188827. Runs the shipped AgentEventsWindow in a real
// AppKit hosting view, appends two events that share seq=1 from different runs, and
// records what the real SwiftUI renderer produces: a PNG of the window, the
// accessibility text rows, and the identity key path the view passes to ForEach.
@MainActor
struct RowIdentityProbe {
    static func event(runId: String, seq: Int, stream: String) -> ControlAgentEvent {
        ControlAgentEvent(
            runId: runId,
            seq: seq,
            stream: stream,
            ts: Double(seq),
            data: [:] as [String: OpenClawProtocol.AnyCodable],
            summary: nil)
    }

    static func writePNG(_ view: NSView, to path: String) -> String {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return "SKIP: empty bounds" }
        let attempts: [(String, () -> Bool)] = [
            ("cacheDisplay", {
                guard let rep = view.bitmapImageRepForFitting(size) else { return false }
                view.cacheDisplay(in: view.bounds, to: rep)
                return write(rep, to: path)
            }),
            ("layer.render", {
                guard let layer = view.layer else { return false }
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width * scale),
                    pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bitmapFormat: [],
                    bytesPerRow: 0,
                    bitsPerPixel: 0)
                else { return false }
                rep.size = size
                guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
                NSGraphicsContext.current = ctx
                ctx.cgContext.scaleBy(x: scale, y: scale)
                layer.render(in: ctx.cgContext)
                NSGraphicsContext.current = nil
                return write(rep, to: path)
            }),
            ("dataWithPDF", {
                let data = view.dataWithPDF(inside: view.bounds)
                let pdfPath = path.hasSuffix(".png") ? String(path.dropLast(4)) + ".pdf" : path + ".pdf"
                return (try? data.write(to: URL(fileURLWithPath: pdfPath))) != nil
            }),
        ]
        for (name, attempt) in attempts {
            if attempt() {
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
                return "OK:\(name) bytes=\(size ?? 0)"
            }
        }
        return "FAIL: no capture method worked"
    }

    static func write(_ rep: NSBitmapImageRep, to path: String) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // Walk the real AppKit accessibility tree of the hosting view and collect text.
    static func accessibilityTexts(_ view: NSView) -> [String] {
        var out: [String] = []
        var visited = 0
        func walk(_ object: Any) {
            visited += 1
            if visited > 4000 { return }
            guard let element = object as? NSObject else { return }
            let label = (element.accessibilityLabel?() ?? nil) as String? ?? ""
            let value = (element.accessibilityValue?() ?? nil) as String? ?? ""
            let title = (element.accessibilityTitle?() ?? nil) as String? ?? ""
            for text in [label, value, title] where !text.isEmpty {
                out.append(text)
            }
            if let children = element.accessibilityChildren?() as [Any]? ?? nil {
                for child in children { walk(child) }
            }
        }
        walk(view)
        return out
    }

    // Find the ForEach node the view builds and dump the identity source it carries.
    static func forEachIdentity(_ value: Any) -> [String] {
        var lines: [String] = []
        var seen = 0
        func walk(_ node: Any, depth: Int, path: String) {
            guard depth < 12, seen < 3000 else { return }
            seen += 1
            let typeName = String(describing: type(of: node))
            let mirror = Mirror(reflecting: node)
            let childCount = mirror.children.count
            if typeName.contains("ForEach") {
                lines.append("FOR_EACH type=\(typeName) children=\(childCount) path=\(path)")
                for (label, child) in mirror.children {
                    lines.append("  child label=\(label) type=\(String(describing: type(of: child))) value=\(String(describing: child).prefix(200))")
                }
            }
            if depth < 6, childCount > 0, childCount < 24 {
                for (index, child) in mirror.children.enumerated() {
                    walk(child.value, depth: depth + 1, path: "\(path).\(child.label ?? "#\(index)")")
                }
            }
        }
        walk(value, depth: 0, path: "body")
        return lines
    }

    @Test
    func `probe window render`() async throws {
        let outputDir = ProcessInfo.processInfo.environment["PROBE_OUT_DIR"] ?? "/tmp/probe-out"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "unknown"
        print("PROBE mode=\(mode) outputDir=\(outputDir)")

        NSApplication.shared.setActivationPolicy(.accessory)
        let store = AgentEventStore.shared
        store.clear()

        print("FOR_EACH_DUMP_BEGIN")
        for line in Self.forEachIdentity(AgentEventsWindow()) { print(line) }
        print("FOR_EACH_DUMP_END")

        // Stage 1: one run in the buffer.
        store.append(Self.event(runId: "run-a", seq: 1, stream: "alpha"))
        let host = NSHostingView(rootView: AgentEventsWindow())
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Agent Events"
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let stageOne = Self.writePNG(host, to: "\(outputDir)/\(mode)-stage1.png")
        print("CAPTURE stage1 \(stageOne)")

        // Stage 2: a second run that restarts seq at 1 (the collision the fix targets).
        store.append(Self.event(runId: "run-b", seq: 1, stream: "beta"))
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let stageTwo = Self.writePNG(host, to: "\(outputDir)/\(mode)-stage2.png")
        print("CAPTURE stage2 \(stageTwo)")

        let texts = Self.accessibilityTexts(host)
        print("AX_TEXTS_BEGIN count=\(texts.count)")
        for text in texts { print("AX: \(text)") }
        print("AX_TEXTS_END")

        let ids = store.events.map(\.id)
        let seqs = store.events.map(\.seq)
        print("BUFFER ids=\(ids) seqs=\(seqs) uniqueIds=\(Set(ids).count) uniqueSeqs=\(Set(seqs).count)")
        print("PROBE_DONE mode=\(mode)")
    }
}
