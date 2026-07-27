import Observation

public struct TranscriptScrollState: Equatable, Sendable {
    public private(set) var followsOutput: Bool
    public private(set) var hasUnseenOutput: Bool

    public init(followsOutput: Bool = true, hasUnseenOutput: Bool = false) {
        self.followsOutput = followsOutput
        self.hasUnseenOutput = hasUnseenOutput
    }

    public mutating func viewportDidChange(isNearBottom: Bool) {
        followsOutput = isNearBottom
        if isNearBottom {
            hasUnseenOutput = false
        }
    }

    @discardableResult
    public mutating func outputDidChange() -> Bool {
        guard followsOutput else {
            hasUnseenOutput = true
            return false
        }
        return true
    }

    public mutating func resumeFollowing() {
        followsOutput = true
        hasUnseenOutput = false
    }
}

@MainActor
@Observable
public final class TranscriptScrollController {
    private var state: TranscriptScrollState
    public private(set) var scrollRequestSequence = 0

    public init(state: TranscriptScrollState = TranscriptScrollState()) {
        self.state = state
    }

    public var followsOutput: Bool { state.followsOutput }
    public var hasUnseenOutput: Bool { state.hasUnseenOutput }

    public func viewportDidChange(isNearBottom: Bool) {
        guard state.followsOutput != isNearBottom
            || (isNearBottom && state.hasUnseenOutput)
        else { return }
        state.viewportDidChange(isNearBottom: isNearBottom)
    }

    @discardableResult
    public func outputDidChange() -> Bool {
        state.outputDidChange()
    }

    public func resumeFollowing() {
        state.resumeFollowing()
        scrollRequestSequence &+= 1
    }
}
