import Testing
import KubecodeKit
@testable import KubecodeApp

@Suite("Agent event dispatch bridge")
struct AgentEventDispatchBridgeTests {
    @Test @MainActor
    func coalesces_a_large_text_burst_into_one_main_actor_delivery() async {
        var deliveries: [[AgentEvent]] = []
        let bridge = AgentEventDispatchBridge { events in
            deliveries.append(events)
        }

        for sequence in 1...1_000 {
            await bridge.enqueue(AgentEvent(
                runID: "run-1",
                sequence: sequence,
                kind: "text_delta",
                payload: ["message_id": .string("message-1"), "text": .string("x")],
                createdAt: "2026-07-26T00:00:00Z"
            ))
        }
        await bridge.flushNow()

        let deliveredEvents = deliveries.flatMap { $0 }
        let reconstructed = deliveredEvents.compactMap {
            $0.payload["text"]?.stringValue
        }.joined()
        #expect(deliveries.count < 100)
        #expect(deliveredEvents.last?.sequence == 1_000)
        #expect(reconstructed.count == 1_000)
    }

    @Test @MainActor
    func flushes_text_before_an_immediate_semantic_event() async {
        var deliveredKinds: [String] = []
        let bridge = AgentEventDispatchBridge { events in
            deliveredKinds.append(contentsOf: events.map(\.kind))
        }
        await bridge.enqueue(AgentEvent(
            runID: "run-1",
            sequence: 1,
            kind: "text_delta",
            payload: ["text": .string("answer")],
            createdAt: "2026-07-26T00:00:00Z"
        ))
        await bridge.enqueue(AgentEvent(
            runID: "run-1",
            sequence: 2,
            kind: "tool_started",
            payload: ["tool_id": .string("tool-1")],
            createdAt: "2026-07-26T00:00:01Z"
        ))

        #expect(deliveredKinds == ["text_delta", "tool_started"])
    }
}
