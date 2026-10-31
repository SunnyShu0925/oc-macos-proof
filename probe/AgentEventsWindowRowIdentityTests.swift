import AppKit
import Foundation
import OpenClawProtocol
import SwiftUI
import Testing
@testable import OpenClaw

// Candidate consumer regression for openclaw PR #188827.
// Drives the shipped AgentEventsWindow through a real AppKit hosting view and reads
// back what SwiftUI rendered, so a `seq`-keyed ForEach cannot pass this test.
@Suite(.serialized, .testWaitLimit)
@MainActor
struct AgentEventsWindowRowIdentityTests {
    private static func event(runId: String, seq: Int) -> ControlAgentEvent {
        ControlAgentEvent(
            runId: runId,
            seq: seq,
            stream: "tool",
            ts: 0,
            data: [:] as [String: OpenClawProtocol.AnyCodable],
            summary: nil)
    }

    @Test
    func `renders separate rows for two runs that restart seq`() async throws {
        _ = AppKitTestSupport.application
        let store = AgentEventStore.shared
        store.clear()
        defer { store.clear() }

        store.append(Self.event(runId: "run-a", seq: 1))
        let hosting = NSHostingView(rootView: AgentEventsWindow())
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()

        // The Gateway restarts seq at 1 for every run, so this row shares run-a's seq.
        store.append(Self.event(runId: "run-b", seq: 1))

        try await TestWait.state("both runs rendered as separate rows") {
            hosting.layoutSubtreeIfNeeded()
            let rendered = try await Self.renderedText(in: hosting)
            return rendered.contains("run-a") && rendered.contains("run-b")
        }
    }

    private static func renderedText(in view: NSView) async throws -> String {
        try await AppKitTestSupport.accessibilityElements(in: view)
            .map { element in
                let name = AppKitTestSupport.accessibilityName(of: element) ?? ""
                let value = element.accessibilityValue?() as? String ?? ""
                return "\(name) \(value)"
            }
            .joined(separator: "\n")
    }
}
