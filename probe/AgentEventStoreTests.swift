import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClaw

@MainActor
struct AgentEventStoreTests {
    @Test
    func `append and clear`() {
        let store = AgentEventStore()
        #expect(store.events.isEmpty)

        store.append(ControlAgentEvent(
            runId: "run",
            seq: 1,
            stream: "test",
            ts: 0,
            data: [:] as [String: OpenClawProtocol.AnyCodable],
            summary: nil))
        #expect(store.events.count == 1)

        store.clear()
        #expect(store.events.isEmpty)
    }

    @Test
    func `trims to max events`() {
        let store = AgentEventStore()
        for i in 1...401 {
            store.append(ControlAgentEvent(
                runId: "run",
                seq: i,
                stream: "test",
                ts: Double(i),
                data: [:] as [String: OpenClawProtocol.AnyCodable],
                summary: nil))
        }

        #expect(store.events.count == 400)
        #expect(store.events.first?.seq == 2)
        #expect(store.events.last?.seq == 401)
    }
}

@MainActor
struct AgentEventsWindowRowIdentityTests {
    @Test
    func `keys rows by the globally unique event id`() {
        // The Gateway restarts seq at 1 for every run, so a seq-keyed ForEach collapses
        // events from different runs into one row. ForEach takes its row identity as the
        // second generic argument, and the built window body exposes it: ControlAgentEvent.id
        // is String, seq is Int. Keying rows by seq renders run-a as Int and loses rows.
        let bodyType = String(describing: type(of: AgentEventsWindow().body))
        #expect(bodyType.contains("ForEach<ReversedCollection<Array<ControlAgentEvent>>, String"))
    }
}
