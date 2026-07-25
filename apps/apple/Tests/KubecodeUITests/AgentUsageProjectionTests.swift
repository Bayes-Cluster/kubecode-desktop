import Foundation
import Testing
import KubecodeKit
@testable import KubecodeUI

@Suite
struct AgentUsageProjectionTests {
    @Test func parses_context_usage_and_optional_session_cost() throws {
        let value = try json(#"{"used":53000,"size":200000,"cost":{"amount":0.045,"currency":"USD"}}"#)

        let usage = try #require(AgentUsageProjection.usage(from: value))

        #expect(usage.used == 53_000)
        #expect(usage.size == 200_000)
        #expect(usage.fraction == 0.265)
        #expect(usage.percentage == 27)
        #expect(usage.cost == AgentUsageCost(amount: 0.045, currency: "USD"))
    }

    @Test func rejects_invalid_token_counts_and_omits_invalid_cost() throws {
        let zeroSize = try json(#"{"used":1,"size":0}"#)
        let fractional = try json(#"{"used":1.5,"size":200000}"#)
        let invalidCost = try json(#"{"used":250000,"size":200000,"cost":{"amount":-1,"currency":""}}"#)

        #expect(AgentUsageProjection.usage(from: zeroSize) == nil)
        #expect(AgentUsageProjection.usage(from: fractional) == nil)
        let usage = try #require(AgentUsageProjection.usage(from: invalidCost))
        #expect(usage.fraction == 1)
        #expect(usage.percentage == 100)
        #expect(usage.cost == nil)
    }

    private func json(_ source: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    }
}
