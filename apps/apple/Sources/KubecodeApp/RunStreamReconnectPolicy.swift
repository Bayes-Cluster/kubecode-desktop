import Foundation

enum RunStreamReconnectDecision: Equatable {
    case retry(afterSequence: Int, delayMilliseconds: Int)
    case stop
}

struct RunStreamReconnectPolicy {
    static let maximumConsecutiveDisconnections = 5

    private(set) var lastSequence: Int
    private var consecutiveDisconnections = 0

    init(initialSequence: Int) {
        lastSequence = initialSequence
    }

    mutating func accept(sequence: Int) -> Bool {
        guard sequence > lastSequence else { return false }
        lastSequence = sequence
        consecutiveDisconnections = 0
        return true
    }

    mutating func recordDisconnection() -> RunStreamReconnectDecision {
        consecutiveDisconnections += 1
        guard consecutiveDisconnections < Self.maximumConsecutiveDisconnections else {
            return .stop
        }
        let delay = min(250 * (1 << (consecutiveDisconnections - 1)), 4_000)
        return .retry(afterSequence: lastSequence, delayMilliseconds: delay)
    }
}
