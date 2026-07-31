#if os(macOS)
import AppKit
import SwiftUI
import KubecodeUI

@MainActor
public final class NativeTranscriptCollectionNSView: NSCollectionView {
    fileprivate var minimumSafeFrameWidth: CGFloat = 1

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(
            width: max(newSize.width, minimumSafeFrameWidth),
            height: newSize.height
        ))
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(NSSize(
            width: max(newSize.width, minimumSafeFrameWidth),
            height: newSize.height
        ))
    }
}

public enum NativeTranscriptResizePolicy: Hashable, Sendable {
    case immediate
    case animated
}

public struct NativeTranscriptCollectionWidthTransition: Equatable, Sendable {
    public struct LayoutVisiblePhase: Equatable, Sendable {
        public let itemWidth: CGFloat
        public let collectionFrameWidth: CGFloat

        public init(itemWidth: CGFloat, collectionFrameWidth: CGFloat) {
            self.itemWidth = itemWidth
            self.collectionFrameWidth = collectionFrameWidth
        }
    }

    public let stagedFrameWidth: CGFloat
    public let settledFrameWidth: CGFloat
    public let minimumClearance: CGFloat
    public let layoutVisiblePhases: [LayoutVisiblePhase]

    public init(
        currentFrameWidth: CGFloat,
        previousItemWidth: CGFloat,
        targetItemWidth: CGFloat,
        horizontalSectionInset: CGFloat,
        minimumClearance: CGFloat
    ) {
        let margin = max(minimumClearance, 1)
        self.minimumClearance = margin
        let previousRequiredWidth = previousItemWidth + horizontalSectionInset + margin
        let targetRequiredWidth = targetItemWidth + horizontalSectionInset + margin
        stagedFrameWidth = max(
            currentFrameWidth,
            max(previousRequiredWidth, targetRequiredWidth)
        )
        settledFrameWidth = targetRequiredWidth
        layoutVisiblePhases = [
            LayoutVisiblePhase(
                itemWidth: previousItemWidth,
                collectionFrameWidth: stagedFrameWidth
            ),
            LayoutVisiblePhase(
                itemWidth: targetItemWidth,
                collectionFrameWidth: stagedFrameWidth
            ),
            LayoutVisiblePhase(
                itemWidth: targetItemWidth,
                collectionFrameWidth: settledFrameWidth
            ),
        ]
    }

    public func preservesFlowLayoutWidthInvariant(horizontalSectionInset: CGFloat) -> Bool {
        layoutVisiblePhases.allSatisfy {
            $0.itemWidth < $0.collectionFrameWidth - horizontalSectionInset
        }
    }
}

public struct NativeTranscriptRenderHeightProvenance: Hashable, Sendable {
    public let itemID: String
    public let contentRevision: Int
    public let outerEffectiveWidth: CGFloat
    public let widthGeneration: Int
    public let sessionID: String?

    public init(
        itemID: String,
        contentRevision: Int,
        outerEffectiveWidth: CGFloat,
        widthGeneration: Int = 0,
        sessionID: String?
    ) {
        self.itemID = itemID
        self.contentRevision = contentRevision
        self.outerEffectiveWidth = max(outerEffectiveWidth, 1)
            .rounded(.toNearestOrAwayFromZero)
        self.widthGeneration = widthGeneration
        self.sessionID = sessionID
    }
}

@MainActor
public struct NativeTranscriptRowRenderContext {
    public let provenance: NativeTranscriptRenderHeightProvenance
    private let publishAction: (NativeTranscriptRenderHeightValue) -> Void

    public var itemID: String { provenance.itemID }
    public var contentRevision: Int { provenance.contentRevision }
    public var outerEffectiveWidth: CGFloat { provenance.outerEffectiveWidth }
    public var sessionID: String? { provenance.sessionID }

    fileprivate init(
        provenance: NativeTranscriptRenderHeightProvenance,
        publishAction: @escaping (NativeTranscriptRenderHeightValue) -> Void
    ) {
        self.provenance = provenance
        self.publishAction = publishAction
    }

    public func publish(_ value: NativeTranscriptRenderHeightValue) {
        publishAction(value)
    }
}

private struct NativeTranscriptRowRenderContextKey: EnvironmentKey {
    static let defaultValue: NativeTranscriptRowRenderContext? = nil
}

public struct NativeTranscriptDisclosureContext: Sendable {
    public let state: TranscriptDisclosureGeometryState

    public init(state: TranscriptDisclosureGeometryState) {
        self.state = state
    }

    public func isExpanded(id: String, fallback: Bool) -> Bool {
        state.presentation(for: id)?.isExpanded ?? fallback
    }
}

private struct NativeTranscriptDisclosureContextKey: EnvironmentKey {
    static let defaultValue: NativeTranscriptDisclosureContext? = nil
}

public extension EnvironmentValues {
    var nativeTranscriptRowRenderContext: NativeTranscriptRowRenderContext? {
        get { self[NativeTranscriptRowRenderContextKey.self] }
        set { self[NativeTranscriptRowRenderContextKey.self] = newValue }
    }

    var nativeTranscriptDisclosureContext: NativeTranscriptDisclosureContext? {
        get { self[NativeTranscriptDisclosureContextKey.self] }
        set { self[NativeTranscriptDisclosureContextKey.self] = newValue }
    }
}

@MainActor
private final class TranscriptHostingItem: NSCollectionViewItem {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override func loadView() {
        view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func apply(_ content: AnyView) {
        hostingView.rootView = content
    }
}

public struct NativeTranscriptItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let contentRevision: Int
    public let layoutRevision: Int
    public let resizePolicy: NativeTranscriptResizePolicy
    public let heightAuthority: NativeTranscriptHeightAuthority

    public init(
        id: String,
        contentRevision: Int,
        layoutRevision: Int = 0,
        resizePolicy: NativeTranscriptResizePolicy = .immediate,
        heightAuthority: NativeTranscriptHeightAuthority = .synchronousHosting
    ) {
        self.id = id
        self.contentRevision = contentRevision
        self.layoutRevision = layoutRevision
        self.resizePolicy = resizePolicy
        self.heightAuthority = heightAuthority
    }

    fileprivate var geometryItem: TranscriptGeometryItem {
        TranscriptGeometryItem(
            id: id,
            contentRevision: contentRevision,
            layoutRevision: layoutRevision,
            heightAuthority: heightAuthority
        )
    }
}

public struct TranscriptCollectionUpdatePlan: Equatable, Sendable {
    public private(set) var reloadsAllItems: Bool
    public private(set) var changedIndexes: IndexSet
    public private(set) var insertedIndexes: IndexSet
    public private(set) var deletedIndexes: IndexSet
    public private(set) var animatesChanges: Bool

    public static let none = TranscriptCollectionUpdatePlan(
        reloadsAllItems: false,
        changedIndexes: [],
        insertedIndexes: [],
        deletedIndexes: [],
        animatesChanges: false
    )

    public static let reloadAll = TranscriptCollectionUpdatePlan(
        reloadsAllItems: true,
        changedIndexes: [],
        insertedIndexes: [],
        deletedIndexes: [],
        animatesChanges: false
    )

    public var hasChanges: Bool {
        reloadsAllItems
            || !changedIndexes.isEmpty
            || !insertedIndexes.isEmpty
            || !deletedIndexes.isEmpty
    }

    public static func between(
        previous: [NativeTranscriptItem],
        current: [NativeTranscriptItem]
    ) -> TranscriptCollectionUpdatePlan {
        let previousIDs = previous.map(\.id)
        let currentIDs = current.map(\.id)
        guard Set(previousIDs).count == previousIDs.count,
              Set(currentIDs).count == currentIDs.count
        else { return .reloadAll }

        let previousIDSet = Set(previousIDs)
        let currentIDSet = Set(currentIDs)
        guard previousIDs.filter(currentIDSet.contains)
                == currentIDs.filter(previousIDSet.contains)
        else { return .reloadAll }

        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let changed = IndexSet(current.indices.filter { index in
            guard let old = previousByID[current[index].id] else { return false }
            return old != current[index]
        })
        let inserted = IndexSet(current.indices.filter { !previousIDSet.contains(current[$0].id) })
        let deleted = IndexSet(previous.indices.filter { !currentIDSet.contains(previous[$0].id) })
        if (!inserted.isEmpty || !deleted.isEmpty), !changed.isEmpty {
            return .reloadAll
        }
        return TranscriptCollectionUpdatePlan(
            reloadsAllItems: false,
            changedIndexes: changed,
            insertedIndexes: inserted,
            deletedIndexes: deleted,
            animatesChanges: inserted.isEmpty && deleted.isEmpty && !changed.isEmpty
                && changed.allSatisfy { current[$0].resizePolicy == .animated }
        )
    }

    public mutating func merge(_ other: TranscriptCollectionUpdatePlan) {
        guard other.hasChanges else { return }
        if reloadsAllItems || other.reloadsAllItems {
            self = .reloadAll
            return
        }
        if !insertedIndexes.isEmpty || !deletedIndexes.isEmpty
            || !other.insertedIndexes.isEmpty || !other.deletedIndexes.isEmpty
        {
            self = .reloadAll
            return
        }
        let hadChanges = !changedIndexes.isEmpty
        changedIndexes.formUnion(other.changedIndexes)
        animatesChanges = hadChanges
            ? animatesChanges && other.animatesChanges
            : other.animatesChanges
    }
}

@MainActor
public struct NativeTranscriptGeometryDrivers {
    public typealias Stage = @MainActor (@escaping @MainActor () -> Void) -> Void
    public typealias WidthSettlementCancellation = @MainActor () -> Void
    public typealias WidthSettlementStage = @MainActor (
        TranscriptWidthSettlementTarget,
        @escaping @MainActor () -> Void
    ) -> WidthSettlementCancellation

    private let preparationStage: Stage
    private let mutationStage: Stage
    private let completionStage: Stage
    private let widthSettlementStage: WidthSettlementStage
    private let viewportAnchorResolver: @MainActor () -> TranscriptGeometryAnchor?

    public init(
        preparation: @escaping Stage,
        mutation: @escaping Stage,
        completion: @escaping Stage,
        widthSettlement: @escaping WidthSettlementStage,
        viewportAnchor: @escaping @MainActor () -> TranscriptGeometryAnchor? = { nil }
    ) {
        preparationStage = preparation
        mutationStage = mutation
        completionStage = completion
        widthSettlementStage = widthSettlement
        viewportAnchorResolver = viewportAnchor
    }

    public static var automatic: NativeTranscriptGeometryDrivers {
        NativeTranscriptGeometryDrivers(
            preparation: { action in
                Task { @MainActor in
                    await Task.yield()
                    action()
                }
            },
            mutation: { action in action() },
            completion: { action in action() },
            widthSettlement: { _, action in
                let task = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    action()
                }
                return { task.cancel() }
            }
        )
    }

    fileprivate func prepare(_ action: @escaping @MainActor () -> Void) {
        preparationStage(action)
    }

    fileprivate func mutate(_ action: @escaping @MainActor () -> Void) {
        mutationStage(action)
    }

    fileprivate func complete(_ action: @escaping @MainActor () -> Void) {
        completionStage(action)
    }

    fileprivate func settleWidth(
        _ target: TranscriptWidthSettlementTarget,
        action: @escaping @MainActor () -> Void
    ) -> WidthSettlementCancellation {
        widthSettlementStage(target, action)
    }

    fileprivate func viewportAnchor() -> TranscriptGeometryAnchor? {
        viewportAnchorResolver()
    }
}

@MainActor
public struct NativeTranscriptCollectionView: NSViewRepresentable {
    public let items: [NativeTranscriptItem]
    public let sessionID: String?
    public let outputRevision: String
    public let bottomInset: CGFloat
    public let disclosures: TranscriptDisclosureGeometryState
    public let scrollController: TranscriptScrollController
    private let geometryDrivers: NativeTranscriptGeometryDrivers
    private let rowBuilder: (Int) -> AnyView

    public init(
        items: [NativeTranscriptItem],
        sessionID: String?,
        outputRevision: String,
        bottomInset: CGFloat,
        disclosures: TranscriptDisclosureGeometryState = .empty,
        scrollController: TranscriptScrollController,
        geometryDrivers: NativeTranscriptGeometryDrivers = .automatic,
        rowBuilder: @escaping (Int) -> AnyView
    ) {
        self.items = items
        self.sessionID = sessionID
        self.outputRevision = outputRevision
        self.bottomInset = bottomInset
        self.disclosures = disclosures
        self.scrollController = scrollController
        self.geometryDrivers = geometryDrivers
        self.rowBuilder = rowBuilder
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.contentView.postsBoundsChangedNotifications = true

        let collectionView = NativeTranscriptCollectionNSView(frame: .zero)
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.allowsEmptySelection = true
        collectionView.frame = scrollView.contentView.bounds
        collectionView.autoresizingMask = []
        let layout = NSCollectionViewFlowLayout()
        layout.minimumLineSpacing = 18
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        scrollView.documentView = collectionView
        context.coordinator.attach(scrollView: scrollView, collectionView: collectionView)
        context.coordinator.apply(parent: self, initial: true)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(parent: self, initial: false)
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        private struct AcceptedRenderHeight {
            let provenance: NativeTranscriptRenderHeightProvenance
            let value: NativeTranscriptRenderHeightValue
        }

        private struct Payload {
            let intentGeneration: Int
            let items: [NativeTranscriptItem]
            let rowBuilder: (Int) -> AnyView
            let sessionID: String?
        }

        private var committedItems: [NativeTranscriptItem] = []
        private var committedRowBuilder: (Int) -> AnyView = { _ in AnyView(EmptyView()) }
        private var committedBottomInset: CGFloat = 0
        private var committedSessionID: String?
        private var desiredItems: [NativeTranscriptItem]
        private var desiredRowBuilder: (Int) -> AnyView
        private var desiredBottomInset: CGFloat
        private var desiredDisclosures: TranscriptDisclosureGeometryState
        private var desiredSessionID: String?
        private var outputRevision: String
        private var scrollRequestSequence: Int
        private var scrollController: TranscriptScrollController
        private let geometryDrivers: NativeTranscriptGeometryDrivers
        private weak var scrollView: NSScrollView?
        private weak var collectionView: NativeTranscriptCollectionNSView?
        private let synchronousMeasurementHost = NSHostingView(rootView: AnyView(EmptyView()))
        private var renderMeasurementHosts: [String: NSHostingView<AnyView>] = [:]
        private var acceptedRenderHeights: [String: AcceptedRenderHeight] = [:]
        private var geometryState: TranscriptGeometryTransactionState
        private var appliedGeometryTarget: TranscriptGeometryTarget
        private var widthSettlementState = TranscriptWidthSettlementState(
            initialEffectiveWidth: 1
        )
        private var pendingPayload: Payload?
        private var inFlightPayload: Payload?
        private var preparationScheduled = false
        private var cancelWidthSettlement: NativeTranscriptGeometryDrivers
            .WidthSettlementCancellation?
        private var authorizedWidthGeneration: Int?
        private var userIntentRevision = 1
        private var lastReportedNearBottom: Bool?
        private var lastViewportWidth: CGFloat?
        private var isLiveScrolling = false

        public private(set) var geometryMutationCount = 0
        public private(set) var geometryCompletionCount = 0
        public var inFlightGeometryGeneration: Int? { geometryState.inFlight?.generation }
        public var pendingGeometryEffectiveWidth: CGFloat? {
            geometryState.pending?.effectiveWidth
        }
        public var pendingWidthSettlement: TranscriptWidthSettlementTarget? {
            widthSettlementState.pending
        }
        public var activeWidthSettlement: TranscriptWidthSettlementTarget? {
            widthSettlementState.active
        }
        public var desiredWidthSettlement: TranscriptWidthSettlementTarget {
            widthSettlementState.latest
        }
        public private(set) var lastReconfiguredItemIDs: Set<String> = []

        public func committedDisclosurePresentation(
            id: String
        ) -> TranscriptDisclosureGeometryPresentation? {
            appliedGeometryTarget.disclosures.presentation(for: id)
        }

        init(parent: NativeTranscriptCollectionView) {
            desiredItems = parent.items
            desiredRowBuilder = parent.rowBuilder
            desiredBottomInset = parent.bottomInset
            desiredDisclosures = parent.disclosures
            desiredSessionID = parent.sessionID
            outputRevision = parent.outputRevision
            scrollRequestSequence = parent.scrollController.scrollRequestSequence
            scrollController = parent.scrollController
            geometryDrivers = parent.geometryDrivers
            let initialGeometry = TranscriptGeometryTarget(
                items: [],
                sizes: [:],
                bottomInset: 0,
                effectiveWidth: 1,
                viewportIntent: .init(revision: 1, mode: .followTail),
                sessionID: parent.sessionID
            )
            geometryState = TranscriptGeometryTransactionState(committed: initialGeometry)
            appliedGeometryTarget = initialGeometry
        }

        fileprivate func attach(
            scrollView: NSScrollView,
            collectionView: NativeTranscriptCollectionNSView
        ) {
            self.scrollView = scrollView
            self.collectionView = collectionView
            lastViewportWidth = scrollView.contentSize.width
            widthSettlementState = TranscriptWidthSettlementState(
                initialEffectiveWidth: availableWidth
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollWillStart),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollDidEnd),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        fileprivate func detach() {
            cancelWidthSettlement?()
            cancelWidthSettlement = nil
            authorizedWidthGeneration = nil
            preparationScheduled = false
            for host in renderMeasurementHosts.values { host.removeFromSuperview() }
            renderMeasurementHosts.removeAll(keepingCapacity: false)
            NotificationCenter.default.removeObserver(self)
            collectionView = nil
            scrollView = nil
            lastViewportWidth = nil
        }

        fileprivate func apply(parent: NativeTranscriptCollectionView, initial: Bool) {
            let changedSession = desiredSessionID != parent.sessionID
            let changedItems = desiredItems != parent.items
            let changedInset = abs(desiredBottomInset - parent.bottomInset) >= 0.5
            let changedDisclosures = desiredDisclosures != parent.disclosures
            let changedOutput = outputRevision != parent.outputRevision
            let changedScrollRequest = scrollRequestSequence
                != parent.scrollController.scrollRequestSequence

            desiredItems = parent.items
            desiredRowBuilder = parent.rowBuilder
            desiredBottomInset = parent.bottomInset
            desiredDisclosures = parent.disclosures
            desiredSessionID = parent.sessionID
            outputRevision = parent.outputRevision
            scrollRequestSequence = parent.scrollController.scrollRequestSequence
            scrollController = parent.scrollController

            if changedSession {
                acceptedRenderHeights.removeAll(keepingCapacity: true)
                removeRenderMeasurementHosts()
                scrollController.resumeFollowing()
                userIntentRevision &+= 1
            }
            if changedScrollRequest {
                userIntentRevision &+= 1
            }
            if changedOutput, !initial {
                _ = scrollController.outputDidChange()
            }

            guard initial || changedSession || changedItems || changedInset
                || changedDisclosures || changedScrollRequest
            else { return }
            if availableWidth <= 1, !desiredItems.isEmpty {
                geometryDrivers.prepare { [weak self] in
                    self?.stageDesiredGeometry(forcesReload: initial || changedSession)
                }
                return
            }
            stageDesiredGeometry(forcesReload: initial || changedSession)
        }

        public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        public func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            committedItems.count
        }

        public func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let hostingItem = TranscriptHostingItem()
            guard committedItems.indices.contains(indexPath.item) else { return hostingItem }
            hostingItem.apply(rowContent(
                at: indexPath.item,
                items: committedItems,
                rowBuilder: committedRowBuilder,
                width: committedEffectiveWidth,
                widthGeneration: appliedGeometryTarget.widthGeneration,
                sessionID: committedSessionID,
                disclosures: appliedGeometryTarget.disclosures
            ))
            return hostingItem
        }

        public func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            let itemWidth = committedEffectiveWidth
            let sectionInset = (collectionViewLayout as? NSCollectionViewFlowLayout)?
                .sectionInset ?? .init()
            let contentInset = scrollView?.contentInsets ?? .init()
            let maximumItemWidth = collectionView.bounds.width
                - sectionInset.left - sectionInset.right
                - contentInset.left - contentInset.right
            assert(
                maximumItemWidth - itemWidth
                    >= flowLayoutClearance,
                "Transcript item width \(itemWidth) is invalid for collection width "
                    + "\(collectionView.bounds.width), section inset \(sectionInset), "
                    + "and content inset \(contentInset)"
            )
            guard committedItems.indices.contains(indexPath.item) else {
                return NSSize(width: itemWidth, height: 1)
            }
            let item = committedItems[indexPath.item]
            let height = appliedGeometryTarget.sizes[item.id]?.height ?? 1
            return NSSize(width: itemWidth, height: height)
        }

        private var committedEffectiveWidth: CGFloat {
            appliedGeometryTarget.effectiveWidth
        }

        private var availableWidth: CGFloat {
            let inset = (collectionView?.collectionViewLayout as? NSCollectionViewFlowLayout)?
                .sectionInset ?? .init()
            let viewportWidth = scrollView?.contentSize.width ?? 0
            let sourceWidth = viewportWidth > 1
                ? viewportWidth
                : (collectionView?.bounds.width ?? 1)
            return floor(max(
                sourceWidth
                    - inset.left - inset.right
                    - flowLayoutClearance,
                1
            ))
        }

        private var flowLayoutClearance: CGFloat {
            guard let scrollView, scrollView.hasVerticalScroller else { return 1 }
            let controlSize = scrollView.verticalScroller?.controlSize ?? .regular
            return NSScroller.scrollerWidth(
                for: controlSize,
                scrollerStyle: scrollView.scrollerStyle
            ) + 1
        }

        private func stageDesiredGeometry(forcesReload: Bool = false) {
            if appliedGeometryTarget.items.isEmpty, geometryState.inFlight == nil {
                let bootstrapWidth = TranscriptWidthSettlementTarget.normalize(availableWidth)
                if bootstrapWidth != widthSettlementState.latest.effectiveWidth {
                    widthSettlementState = TranscriptWidthSettlementState(
                        initialEffectiveWidth: bootstrapWidth
                    )
                }
            }
            let widthTarget = widthSettlementState.latest
            let width = widthTarget.effectiveWidth
            guard width > 1 || desiredItems.isEmpty else { return }
            let geometryItems = desiredItems.map(\.geometryItem)
            let viewportMode: TranscriptGeometryViewportMode
            let carriedDisclosureAnchor: TranscriptGeometryAnchor? = geometryState.inFlight
                .flatMap { transaction -> TranscriptGeometryAnchor? in
                    let mode = transaction.target.viewportIntent.mode
                    guard transaction.target.sessionID == desiredSessionID,
                          case let .preserveDisclosure(anchor) = mode
                    else { return nil }
                    return anchor
                }
            let changedDisclosureOwnerID = desiredDisclosures.presentations.first { presentation in
                geometryState.committed.disclosures.presentation(for: presentation.id) != presentation
            }?.ownerItemID
            if let carriedDisclosureAnchor {
                viewportMode = .preserveDisclosure(carriedDisclosureAnchor)
            } else if let changedDisclosureOwnerID,
               let anchor = viewportAnchor(itemID: changedDisclosureOwnerID)
            {
                viewportMode = .preserveDisclosure(anchor)
            } else if scrollController.followsOutput {
                viewportMode = .followTail
            } else if let anchor = viewportAnchor() {
                viewportMode = .preserve(anchor)
            } else if let first = committedItems.first ?? desiredItems.first {
                viewportMode = .preserve(.init(itemID: first.id, offset: 0))
            } else {
                viewportMode = .followTail
            }
            let target = TranscriptGeometryTarget(
                items: geometryItems,
                sizes: reusableSizes(
                    for: geometryItems,
                    width: width,
                    widthGeneration: widthTarget.generation,
                    sessionID: desiredSessionID
                ),
                bottomInset: desiredBottomInset,
                effectiveWidth: width,
                widthGeneration: widthTarget.generation,
                viewportIntent: .init(revision: userIntentRevision, mode: viewportMode),
                forcesReload: forcesReload,
                sessionID: desiredSessionID,
                disclosures: desiredDisclosures
            )
            guard let intentGeneration = geometryState.submit(target) else { return }
            pendingPayload = Payload(
                intentGeneration: intentGeneration,
                items: desiredItems,
                rowBuilder: desiredRowBuilder,
                sessionID: desiredSessionID
            )
            let desiredIDs = Set(desiredItems.map(\.id))
            let obsoleteHostIDs = renderMeasurementHosts.keys.filter { !desiredIDs.contains($0) }
            for id in obsoleteHostIDs {
                renderMeasurementHosts.removeValue(forKey: id)?.removeFromSuperview()
            }
            if widthSettlementState.pending == nil
                || authorizedWidthGeneration == widthTarget.generation
            {
                schedulePreparation()
            }
        }

        private func reusableSizes(
            for items: [TranscriptGeometryItem],
            width: CGFloat,
            widthGeneration: Int,
            sessionID: String?
        ) -> [String: TranscriptGeometryItemSize] {
            var result: [String: TranscriptGeometryItemSize] = [:]
            for item in items {
                guard let size = geometryState.committed.sizes[item.id],
                      size.matches(
                        item,
                        effectiveWidth: width,
                        widthGeneration: widthGeneration
                      )
                else { continue }
                if item.heightAuthority == .versionedRender {
                    guard let accepted = acceptedRenderHeight(
                        for: item,
                        width: width,
                        widthGeneration: widthGeneration,
                        sessionID: sessionID
                    ),
                          accepted.key.contentVersion == size.contentVersion,
                          accepted.key.renderPublicationVersion == size.renderPublicationVersion
                    else { continue }
                }
                result[item.id] = size
            }
            return result
        }

        private func schedulePreparation() {
            guard !preparationScheduled else { return }
            preparationScheduled = true
            geometryDrivers.prepare { [weak self] in
                guard let self else { return }
                self.preparationScheduled = false
                self.prepareLatestGeometry()
            }
        }

        private func prepareLatestGeometry() {
            guard let payload = pendingPayload,
                  let pending = geometryState.pending,
                  payload.intentGeneration < geometryState.nextIntentGeneration
            else {
                launchReadyTransaction()
                return
            }

            for index in payload.items.indices {
                let nativeItem = payload.items[index]
                let item = nativeItem.geometryItem
                if pending.sizes[item.id]?.matches(
                    item,
                    effectiveWidth: pending.effectiveWidth,
                    widthGeneration: pending.widthGeneration
                ) == true {
                    continue
                }

                let renderHeight = acceptedRenderHeight(
                    for: item,
                    width: pending.effectiveWidth,
                    widthGeneration: pending.widthGeneration,
                    sessionID: payload.sessionID
                )
                let host: NSHostingView<AnyView>
                if nativeItem.heightAuthority == .versionedRender {
                    host = renderMeasurementHost(for: item.id)
                } else {
                    host = synchronousMeasurementHost
                }
                host.rootView = rowContent(
                    at: index,
                    items: payload.items,
                    rowBuilder: payload.rowBuilder,
                    width: pending.effectiveWidth,
                    widthGeneration: pending.widthGeneration,
                    sessionID: payload.sessionID,
                    disclosures: pending.disclosures
                )
                host.frame = NSRect(
                    x: -100_000,
                    y: -100_000,
                    width: pending.effectiveWidth,
                    height: 10_000
                )
                host.layoutSubtreeIfNeeded()
                let height = max(1, ceil(host.fittingSize.height))
                let accepted = renderHeight ?? acceptedRenderHeight(
                    for: item,
                    width: pending.effectiveWidth,
                    widthGeneration: pending.widthGeneration,
                    sessionID: payload.sessionID
                )
                if nativeItem.heightAuthority == .versionedRender, accepted == nil {
                    continue
                }
                let size = TranscriptGeometryItemSize(
                    itemID: item.id,
                    contentRevision: item.contentRevision,
                    layoutRevision: item.layoutRevision,
                    contentVersion: accepted?.key.contentVersion ?? 0,
                    renderPublicationVersion: accepted?.key.renderPublicationVersion ?? 0,
                    effectiveWidth: pending.effectiveWidth,
                    widthGeneration: pending.widthGeneration,
                    height: height
                )
                _ = geometryState.accept(size, intentGeneration: payload.intentGeneration)
                if nativeItem.heightAuthority == .versionedRender {
                    renderMeasurementHosts.removeValue(forKey: item.id)?.removeFromSuperview()
                }
            }
            launchReadyTransaction()
        }

        private func renderMeasurementHost(for itemID: String) -> NSHostingView<AnyView> {
            if let host = renderMeasurementHosts[itemID] { return host }
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            host.alphaValue = 0
            host.frame = NSRect(x: -100_000, y: -100_000, width: 1, height: 1)
            scrollView?.contentView.addSubview(host)
            renderMeasurementHosts[itemID] = host
            return host
        }

        private func acceptedRenderHeight(
            for item: TranscriptGeometryItem,
            width: CGFloat,
            widthGeneration: Int,
            sessionID: String?
        ) -> NativeTranscriptRenderHeightValue? {
            guard let accepted = acceptedRenderHeights[item.id],
                  accepted.provenance == NativeTranscriptRenderHeightProvenance(
                    itemID: item.id,
                    contentRevision: item.contentRevision,
                    outerEffectiveWidth: width,
                    widthGeneration: widthGeneration,
                    sessionID: sessionID
                  )
            else { return nil }
            return accepted.value
        }

        private func rowContent(
            at index: Int,
            items: [NativeTranscriptItem],
            rowBuilder: (Int) -> AnyView,
            width: CGFloat,
            widthGeneration: Int,
            sessionID: String?,
            disclosures: TranscriptDisclosureGeometryState
        ) -> AnyView {
            let context: NativeTranscriptRowRenderContext?
            if items.indices.contains(index) {
                let item = items[index]
                let provenance = NativeTranscriptRenderHeightProvenance(
                    itemID: item.id,
                    contentRevision: item.contentRevision,
                    outerEffectiveWidth: width,
                    widthGeneration: widthGeneration,
                    sessionID: sessionID
                )
                context = NativeTranscriptRowRenderContext(
                    provenance: provenance,
                    publishAction: { [weak self] value in
                        self?.acceptRenderHeight(
                            value,
                            provenance: provenance
                        )
                    }
                )
            } else {
                context = nil
            }
            return AnyView(
                rowBuilder(index)
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.nativeTranscriptRowRenderContext, context)
                    .environment(
                        \.nativeTranscriptDisclosureContext,
                        NativeTranscriptDisclosureContext(state: disclosures)
                    )
            )
        }

        @discardableResult
        public func acceptRenderHeight(
            _ value: NativeTranscriptRenderHeightValue,
            provenance: NativeTranscriptRenderHeightProvenance
        ) -> Bool {
            let previouslyAccepted = acceptedRenderHeights[provenance.itemID].flatMap { accepted in
                accepted.provenance.itemID == provenance.itemID
                    && accepted.provenance.contentRevision == provenance.contentRevision
                    && accepted.provenance.sessionID == provenance.sessionID
                    ? accepted
                    : nil
            }
            let previousValue = previouslyAccepted?.value
            let changedOuterWidth = previouslyAccepted.map {
                $0.provenance.outerEffectiveWidth != provenance.outerEffectiveWidth
                    || $0.provenance.widthGeneration != provenance.widthGeneration
            } ?? false
            let isAcceptable: Bool
            if changedOuterWidth, let previousValue {
                let isNewerPublication = value.key.contentVersion > previousValue.key.contentVersion
                    || (value.key.contentVersion == previousValue.key.contentVersion
                        && value.key.renderPublicationVersion
                            > previousValue.key.renderPublicationVersion)
                let isSamePublication = value.key.contentVersion == previousValue.key.contentVersion
                    && value.key.renderPublicationVersion
                        == previousValue.key.renderPublicationVersion
                isAcceptable = isNewerPublication || isSamePublication
            } else {
                isAcceptable = value.isAcceptable(
                    capturedContentRevision: provenance.contentRevision,
                    currentContentRevision: provenance.contentRevision,
                    previous: previousValue,
                    effectiveWidth: value.key.effectiveWidth
                )
            }
            let widthTarget = widthSettlementState.latest
            guard let item = desiredItems.first(where: { $0.id == provenance.itemID }),
                  item.heightAuthority == .versionedRender,
                  provenance == NativeTranscriptRenderHeightProvenance(
                    itemID: item.id,
                    contentRevision: item.contentRevision,
                    outerEffectiveWidth: widthTarget.effectiveWidth,
                    widthGeneration: widthTarget.generation,
                    sessionID: desiredSessionID
                  ),
                  isAcceptable
            else { return false }
            acceptedRenderHeights[item.id] = AcceptedRenderHeight(
                provenance: provenance,
                value: value
            )
            stageDesiredGeometry()
            return true
        }

        private func launchReadyTransaction() {
            guard let readyTarget = geometryState.pending, readyTarget.isReady else { return }
            let beginsWidthSettlement = readyTarget.widthGeneration
                != widthSettlementState.committed.generation
                && readyTarget.widthGeneration != widthSettlementState.active?.generation
            if beginsWidthSettlement {
                guard widthSettlementState.pending?.generation == readyTarget.widthGeneration,
                      authorizedWidthGeneration == readyTarget.widthGeneration
                else { return }
            }
            guard let transaction = geometryState.beginIfReady(),
                  let payload = pendingPayload,
                  payload.intentGeneration == transaction.intentGeneration
            else { return }
            if beginsWidthSettlement {
                _ = widthSettlementState.beginPending(
                    expectedGeneration: transaction.target.widthGeneration
                )
                authorizedWidthGeneration = nil
            }
            pendingPayload = nil
            inFlightPayload = payload
            geometryDrivers.mutate { [weak self] in
                self?.performMutation(transaction, payload: payload)
            }
        }

        private func performMutation(
            _ transaction: TranscriptGeometryTransaction,
            payload: Payload
        ) {
            guard geometryState.inFlight?.generation == transaction.generation,
                  inFlightPayload?.intentGeneration == payload.intentGeneration,
                  let collectionView,
                  let scrollView
            else { return }
            if transaction.target.sessionID != desiredSessionID {
                _ = geometryState.complete(
                    transactionGeneration: transaction.generation,
                    completionProvenance: transaction.completionProvenance,
                    currentUserIntentRevision: userIntentRevision
                )
                _ = widthSettlementState.reject(
                    generation: transaction.target.widthGeneration
                )
                inFlightPayload = nil
                if geometryState.pending?.isReady == true {
                    launchReadyTransaction()
                } else if geometryState.pending != nil {
                    schedulePreparationIfWidthAuthorized()
                }
                return
            }
            geometryMutationCount += 1
            lastReconfiguredItemIDs = []
            committedItems = payload.items
            committedRowBuilder = payload.rowBuilder
            committedBottomInset = transaction.target.bottomInset
            committedSessionID = payload.sessionID
            scrollView.contentInsets.bottom = committedBottomInset
            let sectionInset = (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?
                .sectionInset ?? .init()
            let horizontalSectionInset = sectionInset.left + sectionInset.right
            let widthTransition = NativeTranscriptCollectionWidthTransition(
                currentFrameWidth: collectionView.frame.width,
                previousItemWidth: appliedGeometryTarget.effectiveWidth,
                targetItemWidth: transaction.target.effectiveWidth,
                horizontalSectionInset: horizontalSectionInset,
                minimumClearance: flowLayoutClearance
            )
            assert(widthTransition.preservesFlowLayoutWidthInvariant(
                horizontalSectionInset: horizontalSectionInset
            ))
            collectionView.minimumSafeFrameWidth = widthTransition.stagedFrameWidth
            collectionView.setFrameSize(NSSize(
                width: widthTransition.stagedFrameWidth,
                height: max(collectionView.frame.height, scrollView.documentVisibleRect.height)
            ))
            appliedGeometryTarget = transaction.target.committedValue
            // Replace cached old-width layout attributes while both old and new
            // item widths fit the staged frame. Shrinking the frame before this
            // pass lets FlowLayout validate stale attributes against the target frame.
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
            collectionView.minimumSafeFrameWidth = widthTransition.settledFrameWidth
            collectionView.setFrameSize(NSSize(
                width: widthTransition.settledFrameWidth,
                height: max(collectionView.frame.height, scrollView.documentVisibleRect.height)
            ))

            let hasStructuralChanges = !transaction.mutationPlan.insertedIDs.isEmpty
                || !transaction.mutationPlan.deletedIDs.isEmpty
            if !transaction.mutationPlan.reloadsAllItems, !hasStructuralChanges {
                let reconfiguresAll = transaction.previousTarget.effectiveWidth
                    != transaction.target.effectiveWidth
                    || transaction.previousTarget.widthGeneration
                        != transaction.target.widthGeneration
                reconfigureVisibleItems(
                    changedIDs: reconfiguresAll
                        ? Set(committedItems.map(\.id))
                        : transaction.mutationPlan.changedIDs
                )
            }
            collectionView.collectionViewLayout?.invalidateLayout()

            if transaction.mutationPlan.reloadsAllItems {
                lastReconfiguredItemIDs = Set(committedItems.map(\.id))
                collectionView.reloadData()
                collectionView.layoutSubtreeIfNeeded()
                finishAppKitMutation(
                    generation: transaction.generation,
                    completionProvenance: transaction.completionProvenance
                )
                return
            }

            let previousIDs = transaction.previousItems.map(\.id)
            let currentIDs = transaction.target.items.map(\.id)
            let insertedPaths = Set(transaction.mutationPlan.insertedIDs.compactMap { id in
                currentIDs.firstIndex(of: id).map { IndexPath(item: $0, section: 0) }
            })
            let deletedPaths = Set(transaction.mutationPlan.deletedIDs.compactMap { id in
                previousIDs.firstIndex(of: id).map { IndexPath(item: $0, section: 0) }
            })
            guard !insertedPaths.isEmpty || !deletedPaths.isEmpty else {
                collectionView.layoutSubtreeIfNeeded()
                finishAppKitMutation(
                    generation: transaction.generation,
                    completionProvenance: transaction.completionProvenance
                )
                return
            }
            collectionView.performBatchUpdates {
                if !deletedPaths.isEmpty { collectionView.deleteItems(at: deletedPaths) }
                if !insertedPaths.isEmpty { collectionView.insertItems(at: insertedPaths) }
            } completionHandler: { [weak self] _ in
                self?.finishAppKitMutation(
                    generation: transaction.generation,
                    completionProvenance: transaction.completionProvenance
                )
            }
        }

        private func reconfigureVisibleItems(changedIDs: Set<String>) {
            guard let collectionView, !changedIDs.isEmpty else { return }
            lastReconfiguredItemIDs = changedIDs
            for item in collectionView.visibleItems() {
                guard let hostingItem = item as? TranscriptHostingItem,
                      let indexPath = collectionView.indexPath(for: item),
                      committedItems.indices.contains(indexPath.item),
                      changedIDs.contains(committedItems[indexPath.item].id)
                else { continue }
                hostingItem.apply(rowContent(
                    at: indexPath.item,
                    items: committedItems,
                    rowBuilder: committedRowBuilder,
                    width: committedEffectiveWidth,
                    widthGeneration: appliedGeometryTarget.widthGeneration,
                    sessionID: committedSessionID,
                    disclosures: appliedGeometryTarget.disclosures
                ))
            }
        }

        private func finishAppKitMutation(
            generation: Int,
            completionProvenance: TranscriptGeometryCompletionProvenance
        ) {
            geometryDrivers.complete { [weak self] in
                self?.completeMutation(
                    generation: generation,
                    completionProvenance: completionProvenance
                )
            }
        }

        private func completeMutation(
            generation: Int,
            completionProvenance: TranscriptGeometryCompletionProvenance
        ) {
            guard geometryState.inFlight?.generation == generation else { return }
            scrollView?.layoutSubtreeIfNeeded()
            collectionView?.layoutSubtreeIfNeeded()
            let completion = geometryState.complete(
                transactionGeneration: generation,
                completionProvenance: completionProvenance,
                currentUserIntentRevision: userIntentRevision
            )
            guard completion.accepted else { return }
            _ = widthSettlementState.complete(
                generation: completionProvenance.widthGeneration
            )
            geometryCompletionCount += 1
            inFlightPayload = nil
            if let effect = completion.viewportEffect {
                switch effect {
                case .followTail where scrollController.followsOutput:
                    scrollToBottom()
                case let .preserve(anchor) where !scrollController.followsOutput:
                    restore(anchor: anchor)
                case let .preserveDisclosure(anchor):
                    restore(anchor: anchor)
                default:
                    break
                }
            }
            reportPosition(force: false)
            if geometryState.pending?.isReady == true {
                launchReadyTransaction()
            } else if geometryState.pending != nil {
                schedulePreparationIfWidthAuthorized()
            }
        }

        private func viewportAnchor(itemID: String? = nil) -> TranscriptGeometryAnchor? {
            if let itemID,
               let collectionView,
               let scrollView,
               let index = committedItems.firstIndex(where: { $0.id == itemID }),
               let attributes = collectionView.layoutAttributesForItem(
                   at: IndexPath(item: index, section: 0)
               )
            {
                return TranscriptGeometryAnchor(
                    itemID: itemID,
                    offset: attributes.frame.minY - scrollView.documentVisibleRect.minY
                )
            }
            if let resolved = geometryDrivers.viewportAnchor() { return resolved }
            guard let collectionView, let scrollView else { return nil }
            let visible = collectionView.indexPathsForVisibleItems()
                .sorted { $0.item < $1.item }
            guard let indexPath = visible.first,
                  committedItems.indices.contains(indexPath.item),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            else { return nil }
            return TranscriptGeometryAnchor(
                itemID: committedItems[indexPath.item].id,
                offset: attributes.frame.minY - scrollView.documentVisibleRect.minY
            )
        }

        private func restore(anchor: TranscriptGeometryAnchor) {
            guard let collectionView, let scrollView,
                  let index = committedItems.firstIndex(where: { $0.id == anchor.itemID }),
                  let attributes = collectionView.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                  )
            else { return }
            let origin = NSPoint(
                x: 0,
                y: scrollGeometry.clampedOriginY(attributes.frame.minY - anchor.offset)
            )
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func scrollToBottom() {
            guard let scrollView else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollGeometry.maximumOriginY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            reportPosition(force: true)
        }

        private func viewportWidthDidChange(_ width: CGFloat) {
            guard width > 1 else { return }
            if appliedGeometryTarget.items.isEmpty, geometryState.inFlight == nil {
                let bootstrapWidth = TranscriptWidthSettlementTarget.normalize(availableWidth)
                guard bootstrapWidth != widthSettlementState.latest.effectiveWidth else { return }
                widthSettlementState = TranscriptWidthSettlementState(
                    initialEffectiveWidth: bootstrapWidth
                )
                authorizedWidthGeneration = nil
                cancelWidthSettlement?()
                cancelWidthSettlement = nil
                stageDesiredGeometry()
                return
            }
            guard let target = widthSettlementState.observe(
                effectiveWidth: availableWidth
            ) else { return }
            stageCollectionFrame(for: target)
            authorizedWidthGeneration = nil
            cancelWidthSettlement?()
            cancelWidthSettlement = geometryDrivers.settleWidth(target) { [weak self] in
                guard let self, self.widthSettlementState.pending == target else { return }
                self.cancelWidthSettlement = nil
                self.authorizedWidthGeneration = target.generation
                self.schedulePreparation()
            }
            stageDesiredGeometry()
        }

        private func stageCollectionFrame(for target: TranscriptWidthSettlementTarget) {
            guard let collectionView, let scrollView else { return }
            let sectionInset = (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?
                .sectionInset ?? .init()
            let transition = NativeTranscriptCollectionWidthTransition(
                currentFrameWidth: collectionView.frame.width,
                previousItemWidth: appliedGeometryTarget.effectiveWidth,
                targetItemWidth: target.effectiveWidth,
                horizontalSectionInset: sectionInset.left + sectionInset.right,
                minimumClearance: flowLayoutClearance
            )
            collectionView.minimumSafeFrameWidth = transition.stagedFrameWidth
            collectionView.setFrameSize(NSSize(
                width: transition.stagedFrameWidth,
                height: max(collectionView.frame.height, scrollView.documentVisibleRect.height)
            ))
        }

        private func schedulePreparationIfWidthAuthorized() {
            guard let pending = geometryState.pending else { return }
            if widthSettlementState.pending == nil
                || authorizedWidthGeneration == pending.widthGeneration
            {
                schedulePreparation()
            }
        }

        @objc private func clipViewBoundsDidChange() {
            if let width = scrollView?.contentSize.width,
               lastViewportWidth.map({ abs($0 - width) >= 0.5 }) ?? true
            {
                lastViewportWidth = width
                viewportWidthDidChange(width)
            }
            let isUserNavigation = Self.currentEventIsUserNavigation
            guard isLiveScrolling || isUserNavigation else { return }
            if !isLiveScrolling, isUserNavigation {
                userIntentRevision &+= 1
            }
            reportPosition(force: false)
        }

        @objc private func liveScrollWillStart() {
            isLiveScrolling = true
            userIntentRevision &+= 1
        }

        @objc private func liveScrollDidEnd() {
            isLiveScrolling = false
            reportPosition(force: true)
        }

        private func reportPosition(force: Bool) {
            guard let scrollView else { return }
            let nearBottom = scrollGeometry.distanceFromTail(
                originY: scrollView.documentVisibleRect.origin.y
            ) <= 72
            guard force || nearBottom != lastReportedNearBottom else { return }
            lastReportedNearBottom = nearBottom
            scrollController.viewportDidChange(isNearBottom: nearBottom)
        }

        private var scrollGeometry: TranscriptScrollGeometry {
            TranscriptScrollGeometry(
                documentHeight: scrollView?.documentView?.bounds.height ?? 0,
                viewportHeight: scrollView?.documentVisibleRect.height ?? 0,
                bottomObstructionHeight: committedBottomInset
            )
        }

        private func removeRenderMeasurementHosts() {
            for host in renderMeasurementHosts.values { host.removeFromSuperview() }
            renderMeasurementHosts.removeAll(keepingCapacity: true)
        }

        private static var currentEventIsUserNavigation: Bool {
            guard let type = NSApp.currentEvent?.type else { return false }
            return type == .scrollWheel || type == .leftMouseDragged || type == .keyDown
        }
    }
}
#endif
