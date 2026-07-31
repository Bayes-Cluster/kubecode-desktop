#if os(macOS)
import AppKit
import SwiftUI
import KubecodeUI

@MainActor
public final class NativeTranscriptCollectionNSView: NSCollectionView {}

public enum NativeTranscriptResizePolicy: Hashable, Sendable {
    case immediate
    case animated
}

@MainActor
public struct NativeTranscriptRowRenderContext {
    public let itemID: String
    public let contentRevision: Int
    private let publishAction: (NativeTranscriptRenderHeightValue) -> Void

    fileprivate init(
        itemID: String,
        contentRevision: Int,
        publishAction: @escaping (NativeTranscriptRenderHeightValue) -> Void
    ) {
        self.itemID = itemID
        self.contentRevision = contentRevision
        self.publishAction = publishAction
    }

    public func publish(_ value: NativeTranscriptRenderHeightValue) {
        publishAction(value)
    }
}

private struct NativeTranscriptRowRenderContextKey: EnvironmentKey {
    static let defaultValue: NativeTranscriptRowRenderContext? = nil
}

public extension EnvironmentValues {
    var nativeTranscriptRowRenderContext: NativeTranscriptRowRenderContext? {
        get { self[NativeTranscriptRowRenderContextKey.self] }
        set { self[NativeTranscriptRowRenderContextKey.self] = newValue }
    }
}

@MainActor
private final class TranscriptHostingItem: NSCollectionViewItem {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override func loadView() {
        view = NSView(frame: .zero)
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

@MainActor
public struct NativeTranscriptItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let contentRevision: Int
    public let layoutRevision: Int
    public let resizePolicy: NativeTranscriptResizePolicy

    public init(
        id: String,
        contentRevision: Int,
        layoutRevision: Int = 0,
        resizePolicy: NativeTranscriptResizePolicy = .immediate
    ) {
        self.id = id
        self.contentRevision = contentRevision
        self.layoutRevision = layoutRevision
        self.resizePolicy = resizePolicy
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
        let previousCommon = previousIDs.filter(currentIDSet.contains)
        let currentCommon = currentIDs.filter(previousIDSet.contains)
        guard previousCommon == currentCommon else { return .reloadAll }

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
            animatesChanges: inserted.isEmpty && deleted.isEmpty && !changed.isEmpty && changed.allSatisfy {
                current[$0].resizePolicy == .animated
            }
        )
    }

    public mutating func merge(_ other: TranscriptCollectionUpdatePlan) {
        guard other.hasChanges else { return }
        if reloadsAllItems || other.reloadsAllItems {
            self = .reloadAll
            return
        }
        if !insertedIndexes.isEmpty || !deletedIndexes.isEmpty
            || !other.insertedIndexes.isEmpty || !other.deletedIndexes.isEmpty {
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
public struct NativeTranscriptCollectionView: NSViewRepresentable {
    public let items: [NativeTranscriptItem]
    public let sessionID: String?
    public let outputRevision: String
    public let bottomInset: CGFloat
    public let scrollController: TranscriptScrollController
    private let rowBuilder: (Int) -> AnyView

    public init(
        items: [NativeTranscriptItem],
        sessionID: String?,
        outputRevision: String,
        bottomInset: CGFloat,
        scrollController: TranscriptScrollController,
        rowBuilder: @escaping (Int) -> AnyView
    ) {
        self.items = items
        self.sessionID = sessionID
        self.outputRevision = outputRevision
        self.bottomInset = bottomInset
        self.scrollController = scrollController
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
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true

        let collectionView = NativeTranscriptCollectionNSView(frame: .zero)
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.allowsEmptySelection = true
        collectionView.frame = scrollView.contentView.bounds
        collectionView.autoresizingMask = [.width]
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
            let contentRevision: Int
            let value: NativeTranscriptRenderHeightValue
        }

        private var items: [NativeTranscriptItem]
        private var pendingItems: [NativeTranscriptItem]
        private var rowBuilder: (Int) -> AnyView
        private var pendingRowBuilder: (Int) -> AnyView
        private var sessionID: String?
        private var outputRevision: String
        private var bottomInset: CGFloat
        private var scrollController: TranscriptScrollController
        private weak var scrollView: NSScrollView?
        private weak var collectionView: NativeTranscriptCollectionNSView?
        private let measurementHost = NSHostingView(rootView: AnyView(EmptyView()))
        private var heightCache = TranscriptHeightCache()
        private var renderHeights: [String: AcceptedRenderHeight] = [:]
        private var layoutGate = TranscriptLayoutGate()
        private var pendingLayoutTask: Task<Void, Never>?
        private var finalWidthLayoutTask: Task<Void, Never>?
        private var semanticRevision = 0
        private var requiresFullReload = false
        private var pendingFollowTail = false
        private var lastReportedNearBottom: Bool?
        private var lastViewportWidth: CGFloat?
        private var isLiveScrolling = false

        init(parent: NativeTranscriptCollectionView) {
            items = parent.items
            pendingItems = parent.items
            rowBuilder = parent.rowBuilder
            pendingRowBuilder = parent.rowBuilder
            sessionID = parent.sessionID
            outputRevision = parent.outputRevision
            bottomInset = parent.bottomInset
            scrollController = parent.scrollController
        }

        fileprivate func attach(
            scrollView: NSScrollView,
            collectionView: NativeTranscriptCollectionNSView
        ) {
            self.scrollView = scrollView
            self.collectionView = collectionView
            lastViewportWidth = scrollView.contentSize.width
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
            pendingLayoutTask?.cancel()
            pendingLayoutTask = nil
            finalWidthLayoutTask?.cancel()
            finalWidthLayoutTask = nil
            NotificationCenter.default.removeObserver(self)
            collectionView = nil
            scrollView = nil
            lastViewportWidth = nil
        }

        fileprivate func apply(parent: NativeTranscriptCollectionView, initial: Bool) {
            let changedSession = sessionID != parent.sessionID
            let changedItems = pendingItems != parent.items
            let changedInset = abs(bottomInset - parent.bottomInset) >= 0.5
            let changedOutput = outputRevision != parent.outputRevision
            let changedScrollRequest = scrollController.scrollRequestSequence
                != parent.scrollController.scrollRequestSequence
            let updatePlan = initial || changedSession
                ? TranscriptCollectionUpdatePlan.reloadAll
                : TranscriptCollectionUpdatePlan.between(previous: pendingItems, current: parent.items)

            if changedSession {
                heightCache.removeAll()
                renderHeights.removeAll(keepingCapacity: true)
            } else if !updatePlan.reloadsAllItems {
                for index in updatePlan.changedIndexes where parent.items.indices.contains(index) {
                    heightCache.remove(id: parent.items[index].id)
                    renderHeights.removeValue(forKey: parent.items[index].id)
                }
            }
            if initial || changedSession {
                requiresFullReload = true
            }
            if changedInset {
                scrollView?.contentInsets.bottom = parent.bottomInset
            }

            pendingItems = parent.items
            pendingRowBuilder = parent.rowBuilder
            sessionID = parent.sessionID
            outputRevision = parent.outputRevision
            bottomInset = parent.bottomInset
            scrollController = parent.scrollController

            if changedSession {
                scrollController.resumeFollowing()
            }
            if changedItems || changedInset || changedSession || initial {
                semanticRevision &+= 1
                scheduleLayout(preserveAnchor: !scrollController.followsOutput)
            }

            var shouldFollow = initial || changedSession || changedScrollRequest
            if changedOutput, !initial {
                shouldFollow = scrollController.outputDidChange() || shouldFollow
            }
            if shouldFollow, scrollController.followsOutput {
                pendingFollowTail = true
                if !(changedItems || changedInset || changedSession || initial) {
                    scheduleLayout(preserveAnchor: false)
                }
            }
        }

        public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        public func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            items.count
        }

        public func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = TranscriptHostingItem()
            guard items.indices.contains(indexPath.item) else { return item }
            item.apply(rowContent(at: indexPath.item, width: availableWidth))
            return item
        }

        public func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            guard items.indices.contains(indexPath.item) else {
                return NSSize(width: availableWidth, height: 1)
            }
            let item = items[indexPath.item]
            let width = availableWidth
            let key = TranscriptHeightCache.Key(
                id: item.id,
                contentRevision: item.contentRevision,
                layoutRevision: item.layoutRevision,
                renderHeightRevision: renderHeights[item.id].flatMap { accepted in
                    accepted.contentRevision == item.contentRevision
                        ? accepted.value.key.renderPublicationVersion
                        : nil
                } ?? 0,
                width: width
            )
            if let height = heightCache.height(for: key) {
                return NSSize(width: width, height: height)
            }
            measurementHost.rootView = rowContent(at: indexPath.item, width: width)
            measurementHost.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
            let height = max(1, ceil(measurementHost.fittingSize.height))
            heightCache.insert(height, for: key)
            return NSSize(width: width, height: height)
        }

        private func viewportWidthDidChange(_ width: CGFloat) {
            guard width > 1 else { return }
            requiresFullReload = true
            semanticRevision &+= 1
            scheduleLayout(preserveAnchor: true)
            finalWidthLayoutTask?.cancel()
            finalWidthLayoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                self.semanticRevision &+= 1
                self.scheduleLayout(preserveAnchor: true)
            }
        }

        private var availableWidth: CGFloat {
            let inset = (collectionView?.collectionViewLayout as? NSCollectionViewFlowLayout)?.sectionInset
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            return max((collectionView?.bounds.width ?? 1) - inset.left - inset.right, 1)
        }

        private func rowContent(at index: Int, width: CGFloat) -> AnyView {
            let context: NativeTranscriptRowRenderContext?
            if items.indices.contains(index) {
                let item = items[index]
                context = NativeTranscriptRowRenderContext(
                    itemID: item.id,
                    contentRevision: item.contentRevision,
                    publishAction: { [weak self] value in
                        self?.acceptRenderHeight(
                            value,
                            itemID: item.id,
                            contentRevision: item.contentRevision
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
            )
        }

        private func acceptRenderHeight(
            _ value: NativeTranscriptRenderHeightValue,
            itemID: String,
            contentRevision: Int
        ) {
            guard let item = items.first(where: { $0.id == itemID }),
                  value.isAcceptable(
                    capturedContentRevision: contentRevision,
                    currentContentRevision: item.contentRevision,
                    previous: renderHeights[itemID].flatMap { accepted in
                        accepted.contentRevision == item.contentRevision
                            ? accepted.value
                            : nil
                    },
                    effectiveWidth: availableWidth
                  )
            else { return }
            renderHeights[itemID] = AcceptedRenderHeight(
                contentRevision: contentRevision,
                value: value
            )
            heightCache.remove(id: itemID)
            collectionView?.collectionViewLayout?.invalidateLayout()
        }

        private func scheduleLayout(preserveAnchor: Bool) {
            pendingLayoutTask?.cancel()
            let revision = semanticRevision
            pendingLayoutTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                let timestamp = ProcessInfo.processInfo.systemUptime
                let frame = UInt64((timestamp * 60).rounded(.down))
                guard self.layoutGate.requestCommit(
                    frame: frame,
                    semanticRevision: revision,
                    timestamp: timestamp
                ) else {
                    try? await Task.sleep(for: .milliseconds(17))
                    guard !Task.isCancelled else { return }
                    self.scheduleLayout(preserveAnchor: preserveAnchor)
                    return
                }
                self.commitLayout(preserveAnchor: preserveAnchor)
            }
        }

        private func commitLayout(preserveAnchor: Bool) {
            guard let collectionView, scrollView != nil else { return }
            let anchor = preserveAnchor ? viewportAnchor() : nil
            let updatePlan = requiresFullReload
                ? TranscriptCollectionUpdatePlan.reloadAll
                : TranscriptCollectionUpdatePlan.between(
                    previous: items,
                    current: pendingItems
                )
            requiresFullReload = false
            let shouldFollow = pendingFollowTail
            pendingFollowTail = false
            items = pendingItems
            rowBuilder = pendingRowBuilder
            if updatePlan.reloadsAllItems {
                collectionView.reloadData()
                scheduleLayoutCompletion(anchor: anchor, shouldFollow: shouldFollow)
            } else if updatePlan.hasChanges {
                let changedPaths = Set(updatePlan.changedIndexes.map {
                    IndexPath(item: $0, section: 0)
                })
                let insertedPaths = Set(updatePlan.insertedIndexes.map {
                    IndexPath(item: $0, section: 0)
                })
                let deletedPaths = Set(updatePlan.deletedIndexes.map {
                    IndexPath(item: $0, section: 0)
                })
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = updatePlan.animatesChanges ? 0.16 : 0
                    collectionView.collectionViewLayout?.invalidateLayout()
                    collectionView.performBatchUpdates {
                        if !deletedPaths.isEmpty {
                            collectionView.deleteItems(at: deletedPaths)
                        }
                        if !insertedPaths.isEmpty {
                            collectionView.insertItems(at: insertedPaths)
                        }
                        if !changedPaths.isEmpty {
                            collectionView.reloadItems(at: changedPaths)
                        }
                    } completionHandler: { [weak self] _ in
                        self?.scheduleLayoutCompletion(
                            anchor: anchor,
                            shouldFollow: shouldFollow
                        )
                    }
                }
            } else {
                scheduleLayoutCompletion(anchor: anchor, shouldFollow: shouldFollow)
            }
        }

        private func scheduleLayoutCompletion(
            anchor: ViewportAnchor?,
            shouldFollow: Bool
        ) {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.completeLayout(anchor: anchor, shouldFollow: shouldFollow)
            }
        }

        private func completeLayout(anchor: ViewportAnchor?, shouldFollow: Bool) {
            if let anchor, !shouldFollow {
                restore(anchor: anchor)
            } else if shouldFollow || scrollController.followsOutput {
                scrollToBottom()
            }
            reportPosition(force: false)
        }

        private struct ViewportAnchor {
            let id: String
            let offset: CGFloat
        }

        private func viewportAnchor() -> ViewportAnchor? {
            guard let collectionView, let scrollView else { return nil }
            let visible = collectionView.indexPathsForVisibleItems()
                .sorted { $0.item < $1.item }
            guard let indexPath = visible.first,
                  items.indices.contains(indexPath.item),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            else { return nil }
            return ViewportAnchor(
                id: items[indexPath.item].id,
                offset: attributes.frame.minY - scrollView.documentVisibleRect.minY
            )
        }

        private func restore(anchor: ViewportAnchor) {
            guard let collectionView, let scrollView,
                  let index = items.firstIndex(where: { $0.id == anchor.id }),
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

        @objc private func clipViewBoundsDidChange() {
            if let width = scrollView?.contentSize.width,
               lastViewportWidth.map({ abs($0 - width) >= 0.5 }) ?? true {
                lastViewportWidth = width
                viewportWidthDidChange(width)
            }
            guard isLiveScrolling || Self.currentEventIsUserNavigation else { return }
            reportPosition(force: false)
        }

        @objc private func liveScrollWillStart() {
            isLiveScrolling = true
        }

        @objc private func liveScrollDidEnd() {
            isLiveScrolling = false
            reportPosition(force: true)
        }

        private func reportPosition(force: Bool) {
            guard let scrollView else { return }
            let distance = scrollGeometry.distanceFromTail(
                originY: scrollView.documentVisibleRect.origin.y
            )
            let nearBottom = distance <= 72
            guard force || nearBottom != lastReportedNearBottom else { return }
            lastReportedNearBottom = nearBottom
            scrollController.viewportDidChange(isNearBottom: nearBottom)
        }

        private var scrollGeometry: TranscriptScrollGeometry {
            TranscriptScrollGeometry(
                documentHeight: scrollView?.documentView?.bounds.height ?? 0,
                viewportHeight: scrollView?.documentVisibleRect.height ?? 0,
                bottomObstructionHeight: bottomInset
            )
        }

        private static var currentEventIsUserNavigation: Bool {
            guard let type = NSApp.currentEvent?.type else { return false }
            return type == .scrollWheel || type == .leftMouseDragged || type == .keyDown
        }
    }
}
#endif
