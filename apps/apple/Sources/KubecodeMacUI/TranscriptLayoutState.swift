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

public struct TranscriptWidthSettlementTarget: Hashable, Sendable {
    public let generation: Int
    public let effectiveWidth: CGFloat

    public init(generation: Int, effectiveWidth: CGFloat) {
        self.generation = generation
        self.effectiveWidth = Self.normalize(effectiveWidth)
    }

    public static func normalize(_ effectiveWidth: CGFloat) -> CGFloat {
        floor(max(effectiveWidth, 1))
    }
}

public struct TranscriptWidthSettlementState: Equatable, Sendable {
    public private(set) var committed: TranscriptWidthSettlementTarget
    public private(set) var active: TranscriptWidthSettlementTarget?
    public private(set) var pending: TranscriptWidthSettlementTarget?
    public private(set) var nextGeneration = 1
    private var lastObservedWidth: CGFloat

    public init(initialEffectiveWidth: CGFloat) {
        let width = TranscriptWidthSettlementTarget.normalize(initialEffectiveWidth)
        committed = TranscriptWidthSettlementTarget(generation: 0, effectiveWidth: width)
        lastObservedWidth = width
    }

    public var latest: TranscriptWidthSettlementTarget {
        pending ?? active ?? committed
    }

    public var retainedTargetCount: Int {
        (active == nil ? 0 : 1) + (pending == nil ? 0 : 1)
    }

    @discardableResult
    public mutating func observe(effectiveWidth: CGFloat) -> TranscriptWidthSettlementTarget? {
        let width = TranscriptWidthSettlementTarget.normalize(effectiveWidth)
        guard width != lastObservedWidth else { return nil }
        lastObservedWidth = width
        let target = TranscriptWidthSettlementTarget(
            generation: nextGeneration,
            effectiveWidth: width
        )
        nextGeneration &+= 1
        pending = target
        return target
    }

    @discardableResult
    public mutating func beginPending(
        expectedGeneration: Int
    ) -> TranscriptWidthSettlementTarget? {
        guard active == nil,
              let pending,
              pending.generation == expectedGeneration
        else { return nil }
        active = pending
        self.pending = nil
        return pending
    }

    @discardableResult
    public mutating func complete(generation: Int) -> Bool {
        guard let active, active.generation == generation else { return false }
        committed = active
        self.active = nil
        return true
    }

    @discardableResult
    public mutating func reject(generation: Int) -> Bool {
        guard active?.generation == generation else { return false }
        active = nil
        return true
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

public struct TranscriptDisclosureGeometryPresentation: Hashable, Sendable {
    public let id: String
    public let ownerItemID: String
    public let revision: Int
    public let isExpanded: Bool

    public init(
        id: String,
        ownerItemID: String,
        revision: Int,
        isExpanded: Bool
    ) {
        self.id = id
        self.ownerItemID = ownerItemID
        self.revision = revision
        self.isExpanded = isExpanded
    }
}

public struct TranscriptDisclosureGeometryState: Hashable, Sendable {
    public private(set) var presentations: [TranscriptDisclosureGeometryPresentation]

    public static let empty = TranscriptDisclosureGeometryState(presentations: [])

    public init(presentations: [TranscriptDisclosureGeometryPresentation]) {
        self.presentations = presentations
    }

    public var hasUniquePresentationIDs: Bool {
        Set(presentations.map(\.id)).count == presentations.count
    }

    public func presentation(for id: String) -> TranscriptDisclosureGeometryPresentation? {
        presentations.first { $0.id == id }
    }

    @discardableResult
    public mutating func replace(
        _ presentation: TranscriptDisclosureGeometryPresentation
    ) -> Bool {
        guard let index = presentations.firstIndex(where: { $0.id == presentation.id }) else {
            presentations.append(presentation)
            return true
        }
        guard presentations[index] != presentation else { return false }
        presentations[index] = presentation
        return true
    }

    public func changedOwnerItemIDs(
        comparedWith previous: TranscriptDisclosureGeometryState
    ) -> Set<String> {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.presentations.map {
            ($0.id, $0)
        })
        let currentByID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
        let ids = Set(previousByID.keys).union(currentByID.keys)
        return Set(ids.flatMap { id -> [String] in
            let old = previousByID[id]
            let new = currentByID[id]
            guard old != new else { return [] }
            return [old?.ownerItemID, new?.ownerItemID].compactMap { $0 }
        })
    }
}

public struct TranscriptGeometryItemSize: Hashable, Sendable {
    public let itemID: String
    public let contentRevision: Int
    public let layoutRevision: Int
    public let contentVersion: Int
    public let renderPublicationVersion: Int
    public let effectiveWidth: CGFloat
    public let widthGeneration: Int
    public let height: CGFloat

    public init(
        itemID: String,
        contentRevision: Int,
        layoutRevision: Int,
        contentVersion: Int,
        renderPublicationVersion: Int,
        effectiveWidth: CGFloat,
        widthGeneration: Int = 0,
        height: CGFloat
    ) {
        self.itemID = itemID
        self.contentRevision = contentRevision
        self.layoutRevision = layoutRevision
        self.contentVersion = contentVersion
        self.renderPublicationVersion = renderPublicationVersion
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
        self.widthGeneration = widthGeneration
        self.height = max(height, 1)
    }

    public func matches(
        _ item: TranscriptGeometryItem,
        effectiveWidth: CGFloat,
        widthGeneration: Int = 0
    ) -> Bool {
        itemID == item.id
            && contentRevision == item.contentRevision
            && layoutRevision == item.layoutRevision
            && self.effectiveWidth
                == max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
            && self.widthGeneration == widthGeneration
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
    case preserveDisclosure(TranscriptGeometryAnchor)

    public var anchor: TranscriptGeometryAnchor? {
        switch self {
        case .followTail: nil
        case let .preserve(anchor), let .preserveDisclosure(anchor): anchor
        }
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
    public let widthGeneration: Int
    public let viewportIntent: TranscriptGeometryViewportIntent
    public let forcesReload: Bool
    public let sessionID: String?
    public let disclosures: TranscriptDisclosureGeometryState

    public init(
        items: [TranscriptGeometryItem],
        sizes: [String: TranscriptGeometryItemSize],
        bottomInset: CGFloat,
        effectiveWidth: CGFloat,
        widthGeneration: Int = 0,
        viewportIntent: TranscriptGeometryViewportIntent,
        forcesReload: Bool = false,
        sessionID: String? = nil,
        disclosures: TranscriptDisclosureGeometryState = .empty
    ) {
        self.items = items
        self.sizes = sizes
        self.bottomInset = max(bottomInset, 0)
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
        self.widthGeneration = widthGeneration
        self.viewportIntent = viewportIntent
        self.forcesReload = forcesReload
        self.sessionID = sessionID
        self.disclosures = disclosures
    }

    public var hasUniqueItemIDs: Bool {
        Set(items.map(\.id)).count == items.count
    }

    public var hasValidDisclosureProvenance: Bool {
        guard hasUniqueItemIDs else { return false }
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return disclosures.hasUniquePresentationIDs
            && disclosures.presentations.allSatisfy { presentation in
                itemsByID[presentation.ownerItemID]?.layoutRevision == presentation.revision
            }
    }

    public var isReady: Bool {
        hasUniqueItemIDs && hasValidDisclosureProvenance && items.allSatisfy { item in
            sizes[item.id]?.matches(
                item,
                effectiveWidth: effectiveWidth,
                widthGeneration: widthGeneration
            ) == true
        }
    }

    var committedValue: TranscriptGeometryTarget {
        TranscriptGeometryTarget(
            items: items,
            sizes: sizes,
            bottomInset: bottomInset,
            effectiveWidth: effectiveWidth,
            widthGeneration: widthGeneration,
            viewportIntent: viewportIntent,
            forcesReload: false,
            sessionID: sessionID,
            disclosures: disclosures
        )
    }

    @discardableResult
    public mutating func accept(_ size: TranscriptGeometryItemSize) -> Bool {
        guard let item = items.first(where: { $0.id == size.itemID }),
              size.matches(
                item,
                effectiveWidth: effectiveWidth,
                widthGeneration: widthGeneration
              )
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

    public static func between(
        previous: TranscriptGeometryTarget,
        current: TranscriptGeometryTarget
    ) -> TranscriptGeometryMutationPlan {
        let itemPlan = between(previous: previous.items, current: current.items)
        guard !itemPlan.reloadsAllItems else { return itemPlan }
        let currentIDs = Set(current.items.map(\.id))
        let disclosureOwners = current.disclosures.changedOwnerItemIDs(
            comparedWith: previous.disclosures
        ).intersection(currentIDs)
        let changedIDs = itemPlan.changedIDs.union(disclosureOwners)
        if (!itemPlan.insertedIDs.isEmpty || !itemPlan.deletedIDs.isEmpty), !changedIDs.isEmpty {
            return .reloadAll
        }
        return TranscriptGeometryMutationPlan(
            reloadsAllItems: false,
            changedIDs: changedIDs,
            insertedIDs: itemPlan.insertedIDs,
            deletedIDs: itemPlan.deletedIDs
        )
    }
}

public struct TranscriptGeometryCompletionProvenance: Hashable, Sendable {
    public let sessionID: String?
    public let items: [TranscriptGeometryItem]
    public let sizes: [String: TranscriptGeometryItemSize]
    public let effectiveWidth: CGFloat
    public let widthGeneration: Int
    public let disclosures: TranscriptDisclosureGeometryState

    public init(
        sessionID: String?,
        items: [TranscriptGeometryItem],
        sizes: [String: TranscriptGeometryItemSize],
        effectiveWidth: CGFloat,
        widthGeneration: Int = 0,
        disclosures: TranscriptDisclosureGeometryState
    ) {
        self.sessionID = sessionID
        self.items = items
        self.sizes = sizes
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
        self.widthGeneration = widthGeneration
        self.disclosures = disclosures
    }

    public init(target: TranscriptGeometryTarget) {
        self.init(
            sessionID: target.sessionID,
            items: target.items,
            sizes: target.sizes,
            effectiveWidth: target.effectiveWidth,
            widthGeneration: target.widthGeneration,
            disclosures: target.disclosures
        )
    }
}

public struct TranscriptGeometryTransaction: Hashable, Sendable {
    public let generation: Int
    public let intentGeneration: Int
    public let previousTarget: TranscriptGeometryTarget
    public let target: TranscriptGeometryTarget
    public let mutationPlan: TranscriptGeometryMutationPlan
    public let completionProvenance: TranscriptGeometryCompletionProvenance

    public var previousItems: [TranscriptGeometryItem] { previousTarget.items }
}

public enum TranscriptGeometryViewportEffect: Hashable, Sendable {
    case followTail
    case preserve(TranscriptGeometryAnchor)
    case preserveDisclosure(TranscriptGeometryAnchor)
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
        guard target.hasUniqueItemIDs, target.hasValidDisclosureProvenance else { return nil }
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
                previous: committed,
                current: target
            )
        let transaction = TranscriptGeometryTransaction(
            generation: nextTransactionGeneration,
            intentGeneration: intentGeneration,
            previousTarget: committed,
            target: target,
            mutationPlan: plan,
            completionProvenance: TranscriptGeometryCompletionProvenance(target: target)
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
        completionProvenance: TranscriptGeometryCompletionProvenance,
        currentUserIntentRevision: Int
    ) -> TranscriptGeometryCompletion {
        guard let transaction = inFlight,
              transaction.generation == transactionGeneration,
              completionProvenance == transaction.completionProvenance
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
        case let .preserve(anchor), let .preserveDisclosure(anchor):
            let resolvedID = TranscriptGeometryAnchor.resolvedItemID(
                requested: anchor.itemID,
                previous: transaction.previousItems,
                current: transaction.target.items
            )
            guard let resolvedID else {
                return TranscriptGeometryCompletion(accepted: true, viewportEffect: nil)
            }
            let resolved = TranscriptGeometryAnchor(itemID: resolvedID, offset: anchor.offset)
            if case .preserveDisclosure = transaction.target.viewportIntent.mode {
                effect = .preserveDisclosure(resolved)
            } else {
                effect = .preserve(resolved)
            }
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
