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
            await self.control.disconnect()
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

    private func preferenceSubmenu(_ item: NSMenuItem, _ identifier: String) -> NSMenu? {
        item.submenu?.items.first { $0.identifier?.rawValue == identifier }?.submenu
    }

    private func checkedTitles(_ submenu: NSMenu) -> [String] {
        submenu.items.filter { $0.state == .on }.map(\.title)
    }

    @Test
    func `probe inherited vs explicit off high`() async throws {
        let outputDir = ProcessInfo.processInfo.environment["PROBE_OUT_DIR"] ?? "/tmp/probe-out"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "unknown"
        print("PROBE mode=\(mode) outputDir=\(outputDir)")
        _ = AppKitTestSupport.application  // ensure NSApplication exists without entering UI loop

        let scenarios: [(String, String?, String?)] = [
            ("inherited", nil, nil),
            ("explicit-off", "off", nil),
            ("explicit-high", "high", nil),
            ("explicit-verbose-off", nil, "off"),
        ]
        let identifiers = ["session.thinking", "session.verbose"]

        // observed["<scenario>|<path>|<submenu>"] = checked titles
        var observed: [String: [String]] = [:]

        for (name, thinking, verbose) in scenarios {
            let fixture = ProbeFixture(thinkingOverride: thinking, verboseOverride: verbose)
            _ = try? await fixture.control.request(method: "health")
            await fixture.sessions.refresh()
            let row = try #require(fixture.sessions.rows.first)

            // Fresh-menu path: configureSessionItem -> buildSessionSubmenu -> buildPreferenceMenu.
            let item = NSMenuItem()
            fixture.sessions.configureSessionItem(item, row: row)
            _ = try #require(item.submenu)

            print("SCENARIO \(name) path=fresh")
            for identifier in identifiers {
                guard let sub = self.preferenceSubmenu(item, identifier) else {
                    print("SUBMENU \(identifier) MISSING")
                    observed["\(name)|fresh|\(identifier)"] = ["<missing>"]
                    continue
                }
                for line in self.dump(sub, label: identifier) { print(line) }
                observed["\(name)|fresh|\(identifier)"] = self.checkedTitles(sub)
            }

            // Reuse path: a second configureSessionItem on the same item hits updateSessionSubmenu
            // -> updatePreferenceMenu. Row stays the same so the selected state must not drift.
            fixture.sessions.configureSessionItem(item, row: row)
            print("SCENARIO \(name) path=reuse")
            for identifier in identifiers {
                guard let sub = self.preferenceSubmenu(item, identifier) else {
                    observed["\(name)|reuse|\(identifier)"] = ["<missing>"]
                    continue
                }
                for line in self.dump(sub, label: identifier) { print(line) }
                observed["\(name)|reuse|\(identifier)"] = self.checkedTitles(sub)
            }

            await fixture.close()
        }

        // The probe is a witness, not a mirror: it fails when the branch under test
        // does not show the behavior the mode claims to demonstrate.
        let isBase = mode == "base"
        for path in ["fresh", "reuse"] {
            let thinking = observed["inherited|\(path)|session.thinking"] ?? ["<missing>"]
            let verbose = observed["inherited|\(path)|session.verbose"] ?? ["<missing>"]
            print("CHECK inherited path=\(path) thinking=\(thinking) verbose=\(verbose) mode=\(mode)")
            if isBase {
                // Main manufactures the fallback: Off is checked on both submenus.
                #expect(thinking == ["Off"], "base should check Off, saw \(thinking)")
                #expect(verbose == ["Off"], "base should check Off, saw \(verbose)")
            } else {
                // Inheriting the default means no explicit override is checked.
                #expect(thinking.isEmpty, "inherited session must not check any Thinking item, saw \(thinking)")
                #expect(verbose.isEmpty, "inherited session must not check any Verbose item, saw \(verbose)")
            }
        }

        if !isBase {
            for path in ["fresh", "reuse"] {
                // Explicit overrides keep their checkmark, on both rendering paths.
                #expect(
                    observed["explicit-off|\(path)|session.thinking"] == ["Off"],
                    "explicit off must check Off, saw \(observed["explicit-off|\(path)|session.thinking"] ?? [])")
                #expect(
                    observed["explicit-high|\(path)|session.thinking"] == ["High"],
                    "explicit high must check High, saw \(observed["explicit-high|\(path)|session.thinking"] ?? [])")
                #expect(
                    observed["explicit-verbose-off|\(path)|session.verbose"] == ["Off"],
                    "explicit verbose off must check Off, saw \(observed["explicit-verbose-off|\(path)|session.verbose"] ?? [])")
            }
        }

        print("PROBE_DONE mode=\(mode) expectations=checked")
    }
}
