// Proof probe for openclaw PR #188938 (status-menu Off inherit-default).
//
// Runs the shipped StatusMenuSessions against a real AppKit NSMenuItem/NSMenu tree
// driven by a mocked Gateway WebSocket session (the same shape the in-tree test uses),
// and records the actual `.state` of every Thinking/Verbose submenu item plus a window
// bitmap, for three sessions: inherited defaults, explicit Off, and explicit High. It
// exercises both rendering paths (fresh construction via configureSessionItem, and reuse
// via a second configureSessionItem on the same item) that the PR repairs. The probe is
// staged by the GHA workflow; it is not committed to the openclaw repo.
import AppKit
import ConcurrencyExtras
import Foundation
import Observation
import OpenClawChatUI
import OpenClawKit
import Testing
@testable import OpenClaw

@Suite(.serialized, .testWaitLimit)
@MainActor
struct StatusMenuProbe {
    /// A row whose optional overrides the probe can set; `nil` means "inherit agent default".
    private func makeRow(thinking: String?, verbose: String?) -> SessionRow {
        SessionRow(
            id: "main",
            key: "main",
            kind: .direct,
            displayName: "Gateway A",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionId: "main",
            thinkingLevel: thinking,
            verboseLevel: verbose,
            tokens: SessionTokenStats(total: 0, contextTokens: 0),
            color: nil)
    }

    /// Minimal mocked Gateway WebSocket that answers sessions.list with an optional
    /// thinking/verbose override on the single "main" row, mirroring the in-tree fixture.
    @MainActor
    private final class ProbeFixture {
        let session: GatewayTestWebSocketSession
        let gateway: GatewayConnection
        let control: ControlChannel
        let sessions: StatusMenuSessions

        init(thinkingOverride: String?, verboseOverride: String?) {
            let revision = LockIsolated<UInt64>(1)
            let boxedThinking = thinkingOverride
            let boxedVerbose = verboseOverride
            self.session = GatewayTestWebSocketSession(taskFactory: {
                let owner = revision.value == 1 ? "A" : "B"
                return GatewayTestWebSocketTask(sendHook: { socket, message, sendIndex in
                    guard sendIndex > 0,
                          let id = GatewayWebSocketTestSupport.requestID(from: message) else { return }
                    let data: Data
                    switch message {
                    case let .data(value): data = value
                    case let .string(value): data = Data(value.utf8)
                    @unknown default: return
                    }
                    guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let method = frame["method"] as? String else { return }
                    let payload: String
                    switch method {
                    case "sessions.list":
                        // When the override is nil, the row omits the field entirely, matching
                        // the real Gateway projection for a session that inherits the default.
                        let thinkingField = boxedThinking.map { #""thinkingLevel":"\#($0)""# } ?? ""
                        let verboseField = boxedVerbose.map { #""verboseLevel":"\#($0)""# } ?? ""
                        let extras = [thinkingField, verboseField].filter { !$0.isEmpty }.joined(separator: ",")
                        let extraClause = extras.isEmpty ? "" : ",\(extras)"
                        payload = #"""
                        {"path":"/synthetic/\#(owner)/sessions.json","sessions":[
                        {"key":"main","displayName":"Gateway \#(owner)","kind":"direct"\#(extraClause)}]}
                        """#
                    default:
                        payload = #"{"ok":true}"#
                    }
                    let response = #"{"type":"res","id":"\#(id)","ok":true,"payload":\#(payload)}"#
                    socket.emitReceiveSuccess(.data(Data(response.utf8)))
                })
            })
            self.gateway = GatewayConnection(
                testEndpointProvider: {
                    let current = revision.value
                    return GatewayConnection.EndpointSnapshot(
                        config: (URL(string: "ws://127.0.0.1:\(49700 + current)")!, nil, nil),
                        routeAuthority: nil,
                        revision: current)
                },
                currentEndpointRevision: { revision.value },
                sessionBox: WebSocketSessionBox(session: self.session))
            self.control = ControlChannel(gateway: self.gateway, endpointRevision: { revision.value })
            self.sessions = StatusMenuSessions(control: self.control)
        }

        func close() async {
            await self.gateway.close()
        }
    }

    private func dump(_ submenu: NSMenu, label: String) -> [String] {
        var lines: [String] = []
        lines.append("SUBMENU \(label) itemCount=\(submenu.items.count) showsStateColumn=\(submenu.showsStateColumn)")
        for item in submenu.items {
            let value = (item.representedObject as? [String: String])?["value"] ?? "?"
            let stateMark = item.state == .on ? "ON" : "off"
            let title = item.title
            lines.append("  ITEM title=\(title) value=\(value) state=\(stateMark)")
        }
        let anyOn = submenu.items.contains { $0.state == .on }
        lines.append("  ANY_ON=\(anyOn)")
        return lines
    }

    private func submenuStates(item: NSMenuItem, identifier: String) -> [String] {
        guard let menu = item.submenu,
              let sub = menu.items.first(where: { $0.identifier?.rawValue == identifier })?.submenu
        else { return ["SUBMENU \(identifier) MISSING"] }
        return self.dump(sub, label: identifier)
    }

    @Test
    func `probe inherited vs explicit off high`() async throws {
        let outputDir = ProcessInfo.processInfo.environment["PROBE_OUT_DIR"] ?? "/tmp/probe-out"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "unknown"
        print("PROBE mode=\(mode) outputDir=\(outputDir)")
        try? await AppKitTestSupport.startApplication()

        let scenarios: [(String, String?, String?)] = [
            ("inherited", nil, nil),
            ("explicit-off", "off", nil),
            ("explicit-high", "high", nil),
            ("explicit-verbose-off", nil, "off"),
        ]

        for (name, thinking, verbose) in scenarios {
            let fixture = ProbeFixture(thinkingOverride: thinking, verboseOverride: verbose)
            _ = try? await fixture.control.request(method: "health")
            await fixture.sessions.refresh()
            let row = try #require(fixture.sessions.rows.first)

            // Fresh-menu path: configureSessionItem -> buildSessionSubmenu -> buildPreferenceMenu.
            let item = NSMenuItem()
            fixture.sessions.configureSessionItem(item, row: row)
            let menu = try #require(item.submenu)

            print("SCENARIO \(name) path=fresh")
            for identifier in ["session.thinking", "session.verbose"] {
                for line in self.submenuStates(item: item, identifier: identifier) { print(line) }
            }

            // Reuse path: a second configureSessionItem on the same item hits updateSessionSubmenu
            // -> updatePreferenceMenu. Row stays the same so the selected state must not drift.
            fixture.sessions.configureSessionItem(item, row: row)
            print("SCENARIO \(name) path=reuse")
            for identifier in ["session.thinking", "session.verbose"] {
                for line in self.submenuStates(item: item, identifier: identifier) { print(line) }
            }

            // Capture the submenu window bitmap for visual before/after.
            let states = self.captureMenuBitmap(item, to: "\(outputDir)/\(mode)-\(name).png")
            print("CAPTURE \(name) \(states)")

            await fixture.close()
        }

        print("PROBE_DONE mode=\(mode)")
        NSApplication.shared.stop(nil)
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func captureMenuBitmap(_ sessionItem: NSMenuItem, to path: String) -> String {
        guard let submenu = sessionItem.submenu else { return "SKIP: no submenu" }
        // Build a real window to host the submenu so AppKit can rasterize it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentView!.bounds)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Pop the submenu briefly so its items realize state-column drawing; capture host.
        submenu.popUp(positioning: nil, at: NSPoint(x: 8, y: 400), in: host)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        submenu.cancelTracking()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            window.orderOut(nil)
            window.close()
            return "FAIL: no bitmap rep"
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let ink = Self.inkRatio(rep)
        let result: String
        if ink > 0.01, let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            result = "OK ink=\(String(format: "%.3f", ink)) bytes=\(data.count)"
        } else {
            result = "FAIL:blank ink=\(String(format: "%.3f", ink))"
        }
        window.orderOut(nil)
        window.close()
        return result
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
}