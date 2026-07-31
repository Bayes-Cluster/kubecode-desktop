#if os(macOS)
import Foundation

public struct TranscriptScrollGeometry: Equatable, Sendable {
    public let documentHeight: CGFloat
    public let viewportHeight: CGFloat
    public let bottomObstructionHeight: CGFloat

    public init(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomObstructionHeight: CGFloat
    ) {
        self.documentHeight = max(0, documentHeight)
        self.viewportHeight = max(0, viewportHeight)
        self.bottomObstructionHeight = max(0, bottomObstructionHeight)
    }

    public var maximumOriginY: CGFloat {
        max(0, documentHeight + bottomObstructionHeight - viewportHeight)
    }

    public func distanceFromTail(originY: CGFloat) -> CGFloat {
        max(0, maximumOriginY - originY)
    }

    public func clampedOriginY(_ originY: CGFloat) -> CGFloat {
        min(max(0, originY), maximumOriginY)
    }
}

public struct NativeTranscriptRenderHeightKey: Hashable, Sendable {
    public let contentVersion: Int
    public let renderPublicationVersion: Int
    public let effectiveWidth: CGFloat

    public init(
        contentVersion: Int,
        renderPublicationVersion: Int,
        effectiveWidth: CGFloat
    ) {
        self.contentVersion = contentVersion
        self.renderPublicationVersion = renderPublicationVersion
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
    }
}

public struct NativeTranscriptRenderHeightValue: Hashable, Sendable {
    public let key: NativeTranscriptRenderHeightKey
    public let height: CGFloat

    public init(key: NativeTranscriptRenderHeightKey, height: CGFloat) {
        self.key = key
        self.height = max(1, height)
    }

    public func isStrictlyNewer(
        than previous: NativeTranscriptRenderHeightValue?,
        effectiveWidth: CGFloat
    ) -> Bool {
        let width = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
        guard key.effectiveWidth == width else { return false }
        guard let previous else { return true }
        let isNewerPublication = key.contentVersion > previous.key.contentVersion
            || (key.contentVersion == previous.key.contentVersion
                && key.renderPublicationVersion > previous.key.renderPublicationVersion)
        let isSamePublication = key.contentVersion == previous.key.contentVersion
            && key.renderPublicationVersion == previous.key.renderPublicationVersion
        if previous.key.effectiveWidth == width {
            return isNewerPublication
        }
        return isNewerPublication || isSamePublication
    }

    public func isAcceptable(
        capturedContentRevision: Int,
        currentContentRevision: Int,
        previous: NativeTranscriptRenderHeightValue?,
        effectiveWidth: CGFloat
    ) -> Bool {
        capturedContentRevision == currentContentRevision
            && isStrictlyNewer(than: previous, effectiveWidth: effectiveWidth)
    }
}

public struct TranscriptHeightCache: Sendable {
    public struct Key: Hashable, Sendable {
        public let id: String
        public let contentRevision: Int
        public let layoutRevision: Int
        public let renderHeightRevision: Int
        public let width: CGFloat

        public init(
            id: String,
            contentRevision: Int,
            layoutRevision: Int = 0,
            renderHeightRevision: Int = 0,
            width: CGFloat
        ) {
            self.id = id
            self.contentRevision = contentRevision
            self.layoutRevision = layoutRevision
            self.renderHeightRevision = renderHeightRevision
            self.width = width.rounded(.toNearestOrAwayFromZero)
        }
    }

    private let capacity: Int
    private var values: [Key: CGFloat] = [:]
    private var recency: [Key] = []

    public init(capacity: Int = 4_096) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { values.count }

    public mutating func height(for key: Key) -> CGFloat? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    public mutating func insert(_ height: CGFloat, for key: Key) {
        values[key] = height
        touch(key)
        while values.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        values.removeAll(keepingCapacity: keepingCapacity)
        recency.removeAll(keepingCapacity: keepingCapacity)
    }

    public mutating func remove(id: String) {
        let keys = values.keys.filter { $0.id == id }
        for key in keys {
            values.removeValue(forKey: key)
        }
        recency.removeAll { $0.id == id }
    }

    private mutating func touch(_ key: Key) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

public struct TranscriptLayoutGate: Sendable {
    private let maximumCommitsPerSecond: Int
    private var lastFrame: UInt64?
    private var commitTimestamps: [TimeInterval] = []
    private var blockedUntil: TimeInterval = 0

    public init(maximumCommitsPerSecond: Int = 120) {
        self.maximumCommitsPerSecond = max(1, maximumCommitsPerSecond)
    }

    public mutating func requestCommit(
        frame: UInt64,
        semanticRevision: Int,
        timestamp: TimeInterval
    ) -> Bool {
        _ = semanticRevision
        guard timestamp >= blockedUntil, frame != lastFrame else { return false }
        commitTimestamps.removeAll { timestamp - $0 >= 1 }
        guard commitTimestamps.count < maximumCommitsPerSecond else {
            blockedUntil = timestamp + 0.1
            return false
        }
        lastFrame = frame
        commitTimestamps.append(timestamp)
        return true
    }
}
#endif
