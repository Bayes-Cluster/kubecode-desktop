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

public enum NativeTranscriptHeightAuthority: Hashable, Sendable {
    case synchronousHosting
    case versionedRender
}

public struct TranscriptGeometryItem: Hashable, Sendable {
    public let id: String
    public let contentRevision: Int
    public let layoutRevision: Int
    public let heightAuthority: NativeTranscriptHeightAuthority

    public init(
        id: String,
        contentRevision: Int,
        layoutRevision: Int,
        heightAuthority: NativeTranscriptHeightAuthority
    ) {
        self.id = id
        self.contentRevision = contentRevision
        self.layoutRevision = layoutRevision
        self.heightAuthority = heightAuthority
    }
}

public struct TranscriptGeometryItemSize: Hashable, Sendable {
    public let itemID: String
    public let contentRevision: Int
    public let layoutRevision: Int
    public let contentVersion: Int
    public let renderPublicationVersion: Int
    public let effectiveWidth: CGFloat
    public let height: CGFloat

    public init(
        itemID: String,
        contentRevision: Int,
        layoutRevision: Int,
        contentVersion: Int,
        renderPublicationVersion: Int,
        effectiveWidth: CGFloat,
        height: CGFloat
    ) {
        self.itemID = itemID
        self.contentRevision = contentRevision
        self.layoutRevision = layoutRevision
        self.contentVersion = contentVersion
        self.renderPublicationVersion = renderPublicationVersion
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
        self.height = max(height, 1)
    }

    public func matches(_ item: TranscriptGeometryItem, effectiveWidth: CGFloat) -> Bool {
        itemID == item.id
            && contentRevision == item.contentRevision
            && layoutRevision == item.layoutRevision
            && self.effectiveWidth
                == max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
            && (item.heightAuthority == .synchronousHosting
                ? contentVersion == 0 && renderPublicationVersion == 0
                : contentVersion > 0 && renderPublicationVersion > 0)
    }

    fileprivate func isStrictlyNewer(than previous: TranscriptGeometryItemSize) -> Bool {
        contentVersion > previous.contentVersion
            || (contentVersion == previous.contentVersion
                && renderPublicationVersion > previous.renderPublicationVersion)
    }
}

public struct TranscriptGeometryAnchor: Hashable, Sendable {
    public let itemID: String
    public let offset: CGFloat

    public init(itemID: String, offset: CGFloat) {
        self.itemID = itemID
        self.offset = offset
    }

    public static func resolvedItemID(
        requested: String,
        previous: [TranscriptGeometryItem],
        current: [TranscriptGeometryItem]
    ) -> String? {
        let currentIDs = Set(current.map(\.id))
        if currentIDs.contains(requested) { return requested }
        guard let previousIndex = previous.firstIndex(where: { $0.id == requested }) else {
            return current.first?.id
        }
        for item in previous.dropFirst(previousIndex + 1) where currentIDs.contains(item.id) {
            return item.id
        }
        for item in previous[..<previousIndex].reversed() where currentIDs.contains(item.id) {
            return item.id
        }
        return current.first?.id
    }
}

public enum TranscriptGeometryViewportMode: Hashable, Sendable {
    case followTail
    case preserve(TranscriptGeometryAnchor)

    public var anchor: TranscriptGeometryAnchor? {
        guard case let .preserve(anchor) = self else { return nil }
        return anchor
    }
}

public struct TranscriptGeometryViewportIntent: Hashable, Sendable {
    public let revision: Int
    public let mode: TranscriptGeometryViewportMode

    public init(revision: Int, mode: TranscriptGeometryViewportMode) {
        self.revision = revision
        self.mode = mode
    }

    public var anchor: TranscriptGeometryAnchor? { mode.anchor }
}

public struct TranscriptGeometryTarget: Hashable, Sendable {
    public let items: [TranscriptGeometryItem]
    public private(set) var sizes: [String: TranscriptGeometryItemSize]
    public let bottomInset: CGFloat
    public let effectiveWidth: CGFloat
    public let viewportIntent: TranscriptGeometryViewportIntent
    public let forcesReload: Bool

    public init(
        items: [TranscriptGeometryItem],
        sizes: [String: TranscriptGeometryItemSize],
        bottomInset: CGFloat,
        effectiveWidth: CGFloat,
        viewportIntent: TranscriptGeometryViewportIntent,
        forcesReload: Bool = false
    ) {
        self.items = items
        self.sizes = sizes
        self.bottomInset = max(bottomInset, 0)
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
        self.viewportIntent = viewportIntent
        self.forcesReload = forcesReload
    }

    public var hasUniqueItemIDs: Bool {
        Set(items.map(\.id)).count == items.count
    }

    public var isReady: Bool {
        hasUniqueItemIDs && items.allSatisfy { item in
            sizes[item.id]?.matches(item, effectiveWidth: effectiveWidth) == true
        }
    }

    var committedValue: TranscriptGeometryTarget {
        TranscriptGeometryTarget(
            items: items,
            sizes: sizes,
            bottomInset: bottomInset,
            effectiveWidth: effectiveWidth,
            viewportIntent: viewportIntent,
            forcesReload: false
        )
    }

    @discardableResult
    public mutating func accept(_ size: TranscriptGeometryItemSize) -> Bool {
        guard let item = items.first(where: { $0.id == size.itemID }),
              size.matches(item, effectiveWidth: effectiveWidth)
        else { return false }
        if let previous = sizes[item.id] {
            guard size.isStrictlyNewer(than: previous) else { return false }
        }
        sizes[item.id] = size
        return true
    }
}

public struct TranscriptGeometryMutationPlan: Hashable, Sendable {
    public let reloadsAllItems: Bool
    public let changedIDs: Set<String>
    public let insertedIDs: Set<String>
    public let deletedIDs: Set<String>

    public static let none = TranscriptGeometryMutationPlan(
        reloadsAllItems: false,
        changedIDs: [],
        insertedIDs: [],
        deletedIDs: []
    )

    public static let reloadAll = TranscriptGeometryMutationPlan(
        reloadsAllItems: true,
        changedIDs: [],
        insertedIDs: [],
        deletedIDs: []
    )

    public var hasChanges: Bool {
        reloadsAllItems || !changedIDs.isEmpty || !insertedIDs.isEmpty || !deletedIDs.isEmpty
    }

    public static func between(
        previous: [TranscriptGeometryItem],
        current: [TranscriptGeometryItem]
    ) -> TranscriptGeometryMutationPlan {
        let previousIDs = previous.map(\.id)
        let currentIDs = current.map(\.id)
        guard Set(previousIDs).count == previousIDs.count,
              Set(currentIDs).count == currentIDs.count
        else { return .reloadAll }

        let previousSet = Set(previousIDs)
        let currentSet = Set(currentIDs)
        guard previousIDs.filter(currentSet.contains) == currentIDs.filter(previousSet.contains)
        else { return .reloadAll }

        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let changed = Set(current.compactMap { item in
            previousByID[item.id].map { $0 == item ? nil : item.id } ?? nil
        })
        let inserted = currentSet.subtracting(previousSet)
        let deleted = previousSet.subtracting(currentSet)
        if (!inserted.isEmpty || !deleted.isEmpty), !changed.isEmpty {
            return .reloadAll
        }
        return TranscriptGeometryMutationPlan(
            reloadsAllItems: false,
            changedIDs: changed,
            insertedIDs: inserted,
            deletedIDs: deleted
        )
    }
}

public struct TranscriptGeometryTransaction: Hashable, Sendable {
    public let generation: Int
    public let intentGeneration: Int
    public let previousTarget: TranscriptGeometryTarget
    public let target: TranscriptGeometryTarget
    public let mutationPlan: TranscriptGeometryMutationPlan

    public var previousItems: [TranscriptGeometryItem] { previousTarget.items }
}

public enum TranscriptGeometryViewportEffect: Hashable, Sendable {
    case followTail
    case preserve(TranscriptGeometryAnchor)
}

public struct TranscriptGeometryCompletion: Hashable, Sendable {
    public let accepted: Bool
    public let viewportEffect: TranscriptGeometryViewportEffect?

    public static let stale = TranscriptGeometryCompletion(
        accepted: false,
        viewportEffect: nil
    )
}

public struct TranscriptGeometryTransactionState: Sendable {
    public private(set) var committed: TranscriptGeometryTarget
    public private(set) var pending: TranscriptGeometryTarget?
    public private(set) var inFlight: TranscriptGeometryTransaction?
    public private(set) var nextIntentGeneration = 1
    public private(set) var nextTransactionGeneration = 1
    private var pendingIntentGeneration: Int?

    public init(committed: TranscriptGeometryTarget) {
        self.committed = committed
    }

    @discardableResult
    public mutating func submit(_ target: TranscriptGeometryTarget) -> Int? {
        guard target.hasUniqueItemIDs else { return nil }
        if target == committed {
            pending = nil
            pendingIntentGeneration = nil
            return nil
        }
        let generation = nextIntentGeneration
        nextIntentGeneration += 1
        pending = target
        pendingIntentGeneration = generation
        return generation
    }

    @discardableResult
    public mutating func accept(
        _ size: TranscriptGeometryItemSize,
        intentGeneration: Int
    ) -> Bool {
        guard pendingIntentGeneration == intentGeneration, pending != nil else { return false }
        return pending!.accept(size)
    }

    public mutating func beginIfReady() -> TranscriptGeometryTransaction? {
        guard inFlight == nil,
              let target = pending,
              target.isReady,
              let intentGeneration = pendingIntentGeneration
        else { return nil }
        let plan = target.forcesReload
            ? TranscriptGeometryMutationPlan.reloadAll
            : TranscriptGeometryMutationPlan.between(
                previous: committed.items,
                current: target.items
            )
        let transaction = TranscriptGeometryTransaction(
            generation: nextTransactionGeneration,
            intentGeneration: intentGeneration,
            previousTarget: committed,
            target: target,
            mutationPlan: plan
        )
        nextTransactionGeneration += 1
        committed = target.committedValue
        pending = nil
        pendingIntentGeneration = nil
        inFlight = transaction
        return transaction
    }

    public mutating func complete(
        transactionGeneration: Int,
        currentUserIntentRevision: Int
    ) -> TranscriptGeometryCompletion {
        guard let transaction = inFlight,
              transaction.generation == transactionGeneration
        else { return .stale }
        inFlight = nil
        guard pending == nil,
              transaction.target.viewportIntent.revision == currentUserIntentRevision
        else {
            return TranscriptGeometryCompletion(accepted: true, viewportEffect: nil)
        }
        let effect: TranscriptGeometryViewportEffect
        switch transaction.target.viewportIntent.mode {
        case .followTail:
            effect = .followTail
        case let .preserve(anchor):
            let resolvedID = TranscriptGeometryAnchor.resolvedItemID(
                requested: anchor.itemID,
                previous: transaction.previousItems,
                current: transaction.target.items
            )
            guard let resolvedID else {
                return TranscriptGeometryCompletion(accepted: true, viewportEffect: nil)
            }
            effect = .preserve(.init(itemID: resolvedID, offset: anchor.offset))
        }
        return TranscriptGeometryCompletion(accepted: true, viewportEffect: effect)
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
