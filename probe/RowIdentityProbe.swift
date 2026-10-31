import AppKit
import Foundation
import OpenClawProtocol
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

    static func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData else { return 0 }
        let samples = rep.samplesPerPixel
        let rowBytes = rep.bytesPerRow
        let height = rep.pixelsHigh
        let width = rep.pixelsWide
        var ink = 0
        var total = 0
        for y in stride(from: 0, to: height, by: 2) {
            let row = data.advanced(by: y * rowBytes)
            for x in stride(from: 0, to: width, by: 2) {
                let pixel = row.advanced(by: x * samples)
                total += 1
                if samples >= 4 {
                    if pixel[3] > 8 { ink += 1 }
                } else if pixel[0] > 8 {
                    ink += 1
                }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    static func bitmap(_ size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        NSBitmapImageRep(
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
    }

    static func writePNG(_ view: NSView, to path: String) -> String {
        view.window?.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return "SKIP: empty bounds" }
        let scale: CGFloat = 2

        // SwiftUI draws through its layer; cacheDisplay alone yields a blank image here.
        if let layer = view.layer, let rep = Self.bitmap(size, scale: scale) {
            rep.size = size
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                let cg = ctx.cgContext
                cg.saveGState()
                cg.scaleBy(x: scale, y: scale)
                layer.render(in: cg)
                cg.restoreGState()
                NSGraphicsContext.current = nil
                let ink = Self.inkRatio(rep)
                if ink > 0.02, let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    return "OK:layer.render ink=\(String(format: "%.3f", ink)) bytes=\(data.count)"
                }
            }
        }

        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let ink = Self.inkRatio(rep)
            if ink > 0.02, let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                return "OK:cacheDisplay ink=\(String(format: "%.3f", ink)) bytes=\(data.count)"
            }
            return "FAIL:blank ink=\(String(format: "%.3f", ink))"
        }
        return "FAIL: no capture method worked"
    }

    // Real AX tree of the rendered window, using the repo's own accessibility helper.
    static func dumpAccessibility(_ view: NSView) async -> [String] {
        var out: [String] = []
        do {
            let elements = try await AppKitTestSupport.accessibilityElements(in: view)
            out.append("AX_ELEMENTS count=\(elements.count)")
            for element in elements {
                let role = String(describing: element.accessibilityRole?())
                let name = AppKitTestSupport.accessibilityName(of: element) ?? ""
                let rawValue: Any? = element.accessibilityValue?()
                let value = rawValue.map { String(describing: $0) } ?? ""
                guard !name.isEmpty || !value.isEmpty else { continue }
                out.append("AX_EL role=\(role) name=\(name) value=\(value)")
            }
        } catch {
            out.append("AX_ELEMENTS_ERROR \(error)")
        }
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
                    lines.append("  child label=\(label ?? "?") type=\(String(describing: type(of: child))) value=\(String(describing: child).prefix(200))")
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


    static func makeWindow(width: CGFloat, height: CGFloat) -> (NSHostingView<AgentEventsWindow>, NSWindow) {
        let host = NSHostingView(rootView: AgentEventsWindow())
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Agent Events"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    static func tally(_ texts: [String]) -> String {
        let joined = texts.joined(separator: "\n")
        func count(_ needle: String) -> Int {
            joined.components(separatedBy: needle).count - 1
        }
        return "run-a=\(count("run-a")) run-b=\(count("run-b")) ALPHA=\(count("ALPHA")) BETA=\(count("BETA"))"
    }

    @Test
    func `probe window render`() async throws {
        let outputDir = ProcessInfo.processInfo.environment["PROBE_OUT_DIR"] ?? "/tmp/probe-out"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "unknown"
        print("PROBE mode=\(mode) outputDir=\(outputDir)")

        try await AppKitTestSupport.startApplication()
        let store = AgentEventStore.shared

        print("FOR_EACH_DUMP_BEGIN")
        let window = AgentEventsWindow()
        let body: some View = window.body
        print("BODY_TYPE \(String(describing: type(of: body)))")
        for line in Self.forEachIdentity(body) { print(line) }
        print("FOR_EACH_DUMP_END")

        // Scenario A: one row per run, both rows fit on screen.
        store.clear()
        store.append(Self.event(runId: "run-a", seq: 1, stream: "alpha"))
        let (hostA, windowA) = Self.makeWindow(width: 640, height: 520)
        try await Task.sleep(for: .milliseconds(700))
        print("CAPTURE single-stage1 \(Self.writePNG(hostA, to: "\(outputDir)/\(mode)-single-stage1.png"))")
        store.append(Self.event(runId: "run-b", seq: 1, stream: "beta"))
        try await Task.sleep(for: .milliseconds(900))
        hostA.layoutSubtreeIfNeeded()
        print("CAPTURE single-stage2 \(Self.writePNG(hostA, to: "\(outputDir)/\(mode)-single-stage2.png"))")
        let single = await Self.dumpAccessibility(hostA)
        print("AX_TEXTS_BEGIN scenario=single")
        for text in single { print(text) }
        print("AX_SINGLE \(Self.tally(single))")
        print("AX_TEXTS_END")
        windowA.orderOut(nil)
        windowA.close()

        // Scenario B: four rows per run, all seq values collide.
        store.clear()
        for seq in 1...4 {
            store.append(Self.event(runId: "run-a", seq: seq, stream: "alpha"))
        }
        let (hostB, windowB) = Self.makeWindow(width: 760, height: 900)
        try await Task.sleep(for: .milliseconds(700))
        print("CAPTURE many-stage1 \(Self.writePNG(hostB, to: "\(outputDir)/\(mode)-many-stage1.png"))")
        for seq in 1...4 {
            store.append(Self.event(runId: "run-b", seq: seq, stream: "beta"))
        }
        try await Task.sleep(for: .milliseconds(900))
        hostB.layoutSubtreeIfNeeded()
        print("CAPTURE many-stage2 \(Self.writePNG(hostB, to: "\(outputDir)/\(mode)-many-stage2.png"))")
        let many = await Self.dumpAccessibility(hostB)
        print("AX_TEXTS_BEGIN scenario=many")
        for text in many { print(text) }
        print("AX_MANY \(Self.tally(many))")
        print("AX_TEXTS_END")
        windowB.orderOut(nil)
        windowB.close()

        let ids = store.events.map(\.id)
        let seqs = store.events.map(\.seq)
        print("BUFFER ids=\(ids) seqs=\(seqs) uniqueIds=\(Set(ids).count) uniqueSeqs=\(Set(seqs).count)")
        print("PROBE_DONE mode=\(mode)")
        NSApplication.shared.stop(nil)
        try? await Task.sleep(for: .milliseconds(200))
    }
}
