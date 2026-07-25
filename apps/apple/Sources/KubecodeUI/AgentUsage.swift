import Foundation
import KubecodeKit

public struct AgentUsageCost: Equatable, Sendable {
    public let amount: Double
    public let currency: String

    public init(amount: Double, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

public struct AgentUsage: Equatable, Sendable {
    public let used: UInt64
    public let size: UInt64
    public let cost: AgentUsageCost?

    public init(used: UInt64, size: UInt64, cost: AgentUsageCost?) {
        self.used = used
        self.size = size
        self.cost = cost
    }

    public var fraction: Double {
        min(max(Double(used) / Double(size), 0), 1)
    }

    public var percentage: Int {
        Int((fraction * 100).rounded())
    }
}

public enum AgentUsageProjection {
    private static let largestExactlyRepresentableInteger = 9_007_199_254_740_991.0

    public static func usage(from value: JSONValue?) -> AgentUsage? {
        guard let object = value?.objectValue,
              let used = unsignedInteger(object["used"]),
              let size = unsignedInteger(object["size"]),
              size > 0
        else { return nil }
        return AgentUsage(
            used: used,
            size: size,
            cost: cost(from: object["cost"])
        )
    }

    private static func unsignedInteger(_ value: JSONValue?) -> UInt64? {
        guard case let .number(number) = value,
              number.isFinite,
              number >= 0,
              number <= largestExactlyRepresentableInteger,
              number.rounded(.towardZero) == number
        else { return nil }
        return UInt64(number)
    }

    private static func cost(from value: JSONValue?) -> AgentUsageCost? {
        guard let object = value?.objectValue,
              case let .number(amount) = object["amount"],
              amount.isFinite,
              amount >= 0,
              let rawCurrency = object["currency"]?.stringValue
        else { return nil }
        let currency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currency.isEmpty else { return nil }
        return AgentUsageCost(amount: amount, currency: currency)
    }
}
