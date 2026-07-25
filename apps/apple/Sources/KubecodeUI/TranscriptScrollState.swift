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
