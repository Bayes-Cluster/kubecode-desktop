import Foundation
import Testing
import KubecodeKit
@testable import KubecodeUI

@Suite
struct AgentPlanProjectionTests {
    @Test func parses_direct_nested_and_items_wrapped_provider_plans() throws {
        let direct = try json(#"{"entries":[{"content":"Inspect","priority":"medium","status":"completed"}]}"#)
        let nested = try json(#"{"plan":{"entries":[{"content":"Implement","priority":"high","status":"inProgress"}]}}"#)
        let wrapped = try json(#"{"items":{"entries":[{"content":"Verify","status":"unknown"}]}}"#)

        #expect(AgentPlanProjection.entries(from: direct) == [
            AgentPlanEntry(content: "Inspect", priority: "medium", status: .completed),
        ])
        #expect(AgentPlanProjection.entries(from: nested) == [
            AgentPlanEntry(content: "Implement", priority: "high", status: .inProgress),
        ])
        #expect(AgentPlanProjection.entries(from: wrapped) == [
            AgentPlanEntry(content: "Verify", priority: "medium", status: .pending),
        ])
    }

    @Test func ignores_malformed_entries_without_inventing_content() throws {
        let plan = try json(#"{"entries":[{}, {"content":""}, {"content":"Ship"}]}"#)

        #expect(AgentPlanProjection.entries(from: plan) == [
            AgentPlanEntry(content: "Ship", priority: "medium", status: .pending),
        ])
    }

    private func json(_ source: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    }
}
