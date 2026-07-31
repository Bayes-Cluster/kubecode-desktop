import Foundation
import Testing
import KubecodeMacUI
#if os(macOS)
import AppKit
import SwiftUI
@testable import KubecodeApp
import KubecodeUI
#endif

@Suite
struct TranscriptGeometryTransactionTests {
    @Test func one_in_flight_transaction_coalesces_the_latest_full_intent() throws {
        var state = TranscriptGeometryTransactionState(committed: target(sourceRevision: 1))

        #expect(state.submit(target(sourceRevision: 2)) == 1)
        let firstValue = state.beginIfReady()
        let first = try #require(firstValue)
        #expect(first.generation == 1)
        #expect(state.submit(target(sourceRevision: 3, bottomInset: 80)) == 2)
        #expect(state.submit(target(sourceRevision: 4, bottomInset: 96)) == 3)
        #expect(state.beginIfReady() == nil)

        let completion = state.complete(
            transactionGeneration: first.generation,
            currentUserIntentRevision: 1
        )
        #expect(completion.viewportEffect == nil)
        let latestValue = state.beginIfReady()
        let latest = try #require(latestValue)
        #expect(latest.generation == 2)
        #expect(latest.intentGeneration == 3)
        #expect(latest.target.items[0].contentRevision == 4)
        #expect(latest.target.bottomInset == 96)
    }

    @Test func stale_collection_completion_cannot_release_or_move_the_viewport() throws {
        var state = TranscriptGeometryTransactionState(committed: target(sourceRevision: 1))
        _ = state.submit(target(sourceRevision: 2))
        let transactionValue = state.beginIfReady()
        let transaction = try #require(transactionValue)

        let stale = state.complete(
            transactionGeneration: transaction.generation + 99,
            currentUserIntentRevision: 1
        )
        #expect(stale == .stale)
        #expect(state.inFlight?.generation == transaction.generation)

        _ = state.submit(target(sourceRevision: 3, viewportRevision: 2))
        let old = state.complete(
            transactionGeneration: transaction.generation,
            currentUserIntentRevision: 2
        )
        #expect(old.viewportEffect == nil)
        #expect(state.inFlight == nil)
    }

    @Test func delayed_renderer_values_require_exact_item_revision_publication_and_width() {
        var pending = target(sourceRevision: 2, renderPublication: nil)
        let oldRevision = size(
            sourceRevision: 1,
            contentVersion: 1,
            publication: 1,
            width: 400
        )
        let wrongWidth = size(
            sourceRevision: 2,
            contentVersion: 2,
            publication: 2,
            width: 600
        )
        let latest = size(
            sourceRevision: 2,
            contentVersion: 2,
            publication: 2,
            width: 400
        )
        let olderPublication = size(
            sourceRevision: 2,
            contentVersion: 2,
            publication: 1,
            width: 400
        )

        let acceptedOldRevision = pending.accept(oldRevision)
        let acceptedWrongWidth = pending.accept(wrongWidth)
        let acceptedLatest = pending.accept(latest)
        let acceptedOlderPublication = pending.accept(olderPublication)
        let acceptedDuplicate = pending.accept(latest)
        #expect(!acceptedOldRevision)
        #expect(!acceptedWrongWidth)
        #expect(acceptedLatest)
        #expect(!acceptedOlderPublication)
        #expect(!acceptedDuplicate)
        #expect(pending.isReady)
    }

    @Test func delayed_old_renderer_and_collection_completion_commit_only_the_latest_tuple() throws {
        var state = TranscriptGeometryTransactionState(committed: target(sourceRevision: 1))
        _ = state.submit(target(sourceRevision: 2, renderPublication: 2))
        let firstValue = state.beginIfReady()
        let first = try #require(firstValue)

        let latestIntentValue = state.submit(target(
            sourceRevision: 3,
            renderPublication: nil
        ))
        let latestIntent = try #require(latestIntentValue)
        let oldRenderer = size(
            sourceRevision: 2,
            contentVersion: 2,
            publication: 2,
            width: 400
        )
        let latestRenderer = size(
            sourceRevision: 3,
            contentVersion: 3,
            publication: 3,
            width: 400
        )
        let acceptedOld = state.accept(oldRenderer, intentGeneration: latestIntent)
        let acceptedLatest = state.accept(latestRenderer, intentGeneration: latestIntent)
        #expect(!acceptedOld)
        #expect(acceptedLatest)

        let oldCompletion = state.complete(
            transactionGeneration: first.generation,
            currentUserIntentRevision: 1
        )
        #expect(oldCompletion.viewportEffect == nil)
        let latestValue = state.beginIfReady()
        let latest = try #require(latestValue)
        #expect(latest.target.items[0].contentRevision == 3)
        #expect(latest.target.sizes["output"]?.renderPublicationVersion == 3)
    }

    @Test func render_settlement_waits_behind_the_active_collection_transaction() throws {
        var state = TranscriptGeometryTransactionState(committed: target(sourceRevision: 1))
        _ = state.submit(target(sourceRevision: 2, renderPublication: 2))
        let activeValue = state.beginIfReady()
        let active = try #require(activeValue)

        _ = state.submit(target(sourceRevision: 2, renderPublication: 3))
        #expect(state.beginIfReady() == nil)
        _ = state.complete(
            transactionGeneration: active.generation,
            currentUserIntentRevision: 1
        )

        let settlementValue = state.beginIfReady()
        let settlement = try #require(settlementValue)
        #expect(settlement.target.sizes["output"]?.renderPublicationVersion == 3)
    }

    @Test func item_plan_helper_falls_back_for_duplicate_ids() {
        let original = [
            item("one", revision: 1, authority: .synchronousHosting),
            item("two", revision: 1, authority: .synchronousHosting),
        ]
        let changed = [
            item("one", revision: 2, authority: .synchronousHosting),
            item("two", revision: 1, authority: .synchronousHosting),
        ]
        let plan = TranscriptGeometryMutationPlan.between(previous: original, current: changed)
        #expect(plan.changedIDs == ["one"])
        #expect(!plan.reloadsAllItems)

        let inserted = TranscriptGeometryMutationPlan.between(
            previous: original,
            current: [original[0], item("middle", revision: 1, authority: .synchronousHosting), original[1]]
        )
        #expect(inserted.insertedIDs == ["middle"])
        #expect(!inserted.reloadsAllItems)

        let duplicate = TranscriptGeometryMutationPlan.between(
            previous: original,
            current: [original[0], original[0]]
        )
        #expect(duplicate.reloadsAllItems)
    }

    @Test func duplicate_target_is_rejected_without_wedging_the_next_valid_intent() throws {
        let committed = target(sourceRevision: 1)
        var state = TranscriptGeometryTransactionState(committed: committed)
        let duplicateItem = item("duplicate", revision: 1, authority: .synchronousHosting)
        let duplicateSize = TranscriptGeometryItemSize(
            itemID: duplicateItem.id,
            contentRevision: duplicateItem.contentRevision,
            layoutRevision: duplicateItem.layoutRevision,
            contentVersion: 0,
            renderPublicationVersion: 0,
            effectiveWidth: 400,
            height: 40
        )
        let duplicate = TranscriptGeometryTarget(
            items: [duplicateItem, duplicateItem],
            sizes: [duplicateItem.id: duplicateSize],
            bottomInset: 40,
            effectiveWidth: 400,
            viewportIntent: .init(revision: 1, mode: .followTail)
        )

        #expect(state.submit(duplicate) == nil)
        #expect(state.pending == nil)
        #expect(state.nextIntentGeneration == 1)
        #expect(state.submit(target(sourceRevision: 2)) == 1)
        #expect(state.submit(duplicate) == nil)
        #expect(state.pending?.items.first?.contentRevision == 2)
        #expect(state.nextIntentGeneration == 2)
        let transactionValue = state.beginIfReady()
        let transaction = try #require(transactionValue)
        #expect(transaction.generation == 1)
        #expect(transaction.target.items.map(\.id) == ["output"])
    }

#if os(macOS)
    @Test func collection_width_transition_is_valid_during_expansion_and_shrink() {
        let horizontalInset: CGFloat = 36
        let expansion = NativeTranscriptCollectionWidthTransition(
            currentFrameWidth: 637,
            previousItemWidth: 600,
            targetItemWidth: 800,
            horizontalSectionInset: horizontalInset,
            minimumClearance: 18
        )
        let shrink = NativeTranscriptCollectionWidthTransition(
            currentFrameWidth: expansion.settledFrameWidth,
            previousItemWidth: 800,
            targetItemWidth: 420,
            horizontalSectionInset: horizontalInset,
            minimumClearance: 18
        )

        #expect(expansion.layoutVisiblePhases.map(\.itemWidth) == [600, 800, 800])
        #expect(shrink.layoutVisiblePhases.map(\.itemWidth) == [800, 420, 420])
        for phase in expansion.layoutVisiblePhases + shrink.layoutVisiblePhases {
            #expect(phase.itemWidth < phase.collectionFrameWidth - horizontalInset)
        }
        #expect(expansion.stagedFrameWidth == 854)
        #expect(expansion.settledFrameWidth == 854)
        #expect(shrink.stagedFrameWidth == 854)
        #expect(shrink.settledFrameWidth == 474)
    }

    @Test func mounted_markdown_height_authority_tracks_actual_disclosure_content() {
        let user = TranscriptSurfaceHeightAuthority.resolve(
            role: .user,
            presentation: .transcriptItem,
            isExpanded: false
        )
        let collapsedThinking = TranscriptSurfaceHeightAuthority.resolve(
            role: .thinking,
            presentation: .transcriptItem,
            isExpanded: false
        )
        let expandedThinking = TranscriptSurfaceHeightAuthority.resolve(
            role: .thinking,
            presentation: .activityStep,
            isExpanded: true
        )
        #expect(user == .versionedRender)
        #expect(collapsedThinking == .synchronousHosting)
        #expect(expandedThinking == .versionedRender)
        #expect(TranscriptSurfaceHeightAuthority.resolve(
            role: .user,
            presentation: .activityStep,
            isExpanded: true
        ) == .synchronousHosting)
        #expect(TranscriptSurfaceHeightAuthority.resolve(
            role: .agent,
            presentation: .activityStep,
            isExpanded: false
        ) == .versionedRender)

        let userItem = item("user", revision: 1, authority: user)
        var userTarget = TranscriptGeometryTarget(
            items: [userItem],
            sizes: [:],
            bottomInset: 40,
            effectiveWidth: 400,
            viewportIntent: .init(revision: 1, mode: .followTail)
        )
        #expect(!userTarget.isReady)
        let acceptedUser = userTarget.accept(TranscriptGeometryItemSize(
            itemID: userItem.id,
            contentRevision: userItem.contentRevision,
            layoutRevision: userItem.layoutRevision,
            contentVersion: 1,
            renderPublicationVersion: 1,
            effectiveWidth: 400,
            height: 54
        ))
        #expect(acceptedUser)
        #expect(userTarget.isReady)

        let collapsed = item("thinking", revision: 1, authority: collapsedThinking)
        let synchronousSize = TranscriptGeometryItemSize(
            itemID: collapsed.id,
            contentRevision: collapsed.contentRevision,
            layoutRevision: collapsed.layoutRevision,
            contentVersion: 0,
            renderPublicationVersion: 0,
            effectiveWidth: 400,
            height: 28
        )
        #expect(TranscriptGeometryTarget(
            items: [collapsed],
            sizes: [collapsed.id: synchronousSize],
            bottomInset: 40,
            effectiveWidth: 400,
            viewportIntent: .init(revision: 1, mode: .followTail)
        ).isReady)
        #expect(!TranscriptGeometryTarget(
            items: [collapsed],
            sizes: [collapsed.id: TranscriptGeometryItemSize(
                itemID: collapsed.id,
                contentRevision: collapsed.contentRevision,
                layoutRevision: collapsed.layoutRevision,
                contentVersion: 1,
                renderPublicationVersion: 1,
                effectiveWidth: 400,
                height: 80
            )],
            bottomInset: 40,
            effectiveWidth: 400,
            viewportIntent: .init(revision: 1, mode: .followTail)
        ).isReady)

        let expanded = item("thinking", revision: 1, authority: expandedThinking)
        var expandedTarget = TranscriptGeometryTarget(
            items: [expanded],
            sizes: [:],
            bottomInset: 40,
            effectiveWidth: 400,
            viewportIntent: .init(revision: 1, mode: .followTail)
        )
        #expect(!expandedTarget.isReady)
        let acceptedExpanded = expandedTarget.accept(TranscriptGeometryItemSize(
            itemID: expanded.id,
            contentRevision: expanded.contentRevision,
            layoutRevision: expanded.layoutRevision,
            contentVersion: 1,
            renderPublicationVersion: 1,
            effectiveWidth: 400,
            height: 80
        ))
        #expect(acceptedExpanded)
        #expect(expandedTarget.isReady)
    }
#endif

    @Test func tail_and_anchor_intents_are_disjoint_and_latest_revision_wins() throws {
        var state = TranscriptGeometryTransactionState(committed: target(sourceRevision: 1))
        _ = state.submit(target(sourceRevision: 2, viewportRevision: 4))
        let tailValue = state.beginIfReady()
        let tail = try #require(tailValue)
        #expect(tail.target.viewportIntent.mode == .followTail)
        #expect(tail.target.viewportIntent.anchor == nil)
        let tailCompletion = state.complete(
            transactionGeneration: tail.generation,
            currentUserIntentRevision: 4
        )
        #expect(tailCompletion.viewportEffect == .followTail)

        let anchor = TranscriptGeometryAnchor(itemID: "output", offset: 17)
        _ = state.submit(target(
            sourceRevision: 3,
            viewportRevision: 5,
            viewportMode: .preserve(anchor)
        ))
        let awayValue = state.beginIfReady()
        let away = try #require(awayValue)
        let stale = state.complete(
            transactionGeneration: away.generation,
            currentUserIntentRevision: 6
        )
        #expect(stale.viewportEffect == nil)
    }

    @Test func a_deleted_anchor_falls_forward_then_backward_by_stable_id() {
        let previous = [
            item("a", revision: 1, authority: .synchronousHosting),
            item("b", revision: 1, authority: .synchronousHosting),
            item("c", revision: 1, authority: .synchronousHosting),
        ]
        #expect(TranscriptGeometryAnchor.resolvedItemID(
            requested: "b",
            previous: previous,
            current: [previous[0], previous[2]]
        ) == "c")
        #expect(TranscriptGeometryAnchor.resolvedItemID(
            requested: "c",
            previous: previous,
            current: [previous[0]]
        ) == "a")
    }

    @Test func identical_terminal_handoff_is_a_strict_geometry_noop() {
        let committed = target(sourceRevision: 1)
        var state = TranscriptGeometryTransactionState(committed: committed)

        #expect(state.submit(committed) == nil)
        #expect(state.pending == nil)
        #expect(state.beginIfReady() == nil)
        #expect(state.nextIntentGeneration == 1)
        #expect(state.nextTransactionGeneration == 1)
    }

    @Test func a_forced_reload_is_one_shot_not_committed_semantic_state() throws {
        let initial = target(sourceRevision: 1)
        var state = TranscriptGeometryTransactionState(committed: initial)
        let forced = TranscriptGeometryTarget(
            items: initial.items,
            sizes: initial.sizes,
            bottomInset: initial.bottomInset,
            effectiveWidth: initial.effectiveWidth,
            viewportIntent: initial.viewportIntent,
            forcesReload: true
        )
        _ = state.submit(forced)
        let transactionValue = state.beginIfReady()
        let transaction = try #require(transactionValue)
        #expect(transaction.mutationPlan.reloadsAllItems)
        #expect(!state.committed.forcesReload)
        let duplicate = state.submit(initial)
        #expect(duplicate == nil)
    }

    @Test func bottom_inset_changes_only_when_the_transaction_begins() throws {
        let initial = target(sourceRevision: 1, bottomInset: 40)
        var state = TranscriptGeometryTransactionState(committed: initial)
        _ = state.submit(target(sourceRevision: 1, bottomInset: 96))

        #expect(state.committed.bottomInset == 40)
        let transaction = state.beginIfReady()
        _ = try #require(transaction)
        #expect(state.committed.bottomInset == 96)
    }

#if os(macOS)
    @Test @MainActor func manual_collection_phases_serialize_and_commit_atomic_inset() throws {
        let driver = ManualTranscriptGeometryDrivers()
        let scrollController = TranscriptScrollController()
        let controller = NSHostingController(rootView: transcriptView(
            revision: 1,
            bottomInset: 20,
            scrollController: scrollController,
            driver: driver
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(window: window, controller: controller)
        let collection = try #require(descendant(
            of: NativeTranscriptCollectionNSView.self,
            in: controller.view
        ))
        let scrollView = try #require(collection.enclosingScrollView)
        controller.view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 640, height: 320)
        scrollView.frame = controller.view.bounds
        scrollView.layoutSubtreeIfNeeded()
        collection.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        for _ in 0..<4 {
            controller.view.frame = window.contentView?.bounds
                ?? NSRect(x: 0, y: 0, width: 640, height: 320)
            scrollView.frame = controller.view.bounds
            scrollView.contentView.frame = scrollView.bounds
            collection.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
            layout(window: window, controller: controller)
            driver.drainAll()
        }
        layout(window: window, controller: controller)
        let coordinator = try #require(
            collection.delegate as? NativeTranscriptCollectionView.Coordinator
        )
        #expect(driver.preparations.isEmpty)
        #expect(driver.mutations.isEmpty)
        #expect(driver.completions.isEmpty)
        #expect(coordinator.geometryMutationCount == 1)
        try #require(collection.numberOfItems(inSection: 0) == 1)
        let initialSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )
        #expect(scrollView.contentInsets.bottom == 20)

        controller.rootView = transcriptView(
            revision: 2,
            bottomInset: 80,
            scrollController: scrollController,
            driver: driver
        )
        layout(window: window, controller: controller)
        driver.releasePreparation()
        #expect(scrollView.contentInsets.bottom == 20)
        #expect(coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        ) == initialSize)
        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(scrollView.contentInsets.bottom == 80)
        #expect(coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        ).height > initialSize.height)
        let oldCompletion = try #require(driver.completions.first)

        controller.rootView = transcriptView(
            revision: 3,
            bottomInset: 96,
            scrollController: scrollController,
            driver: driver
        )
        layout(window: window, controller: controller)
        driver.releasePreparation()
        #expect(driver.mutations.isEmpty)
        driver.releaseCompletion()
        #expect(driver.mutations.count == 1)
        driver.releaseMutation()
        #expect(scrollView.contentInsets.bottom == 96)

        oldCompletion()
        #expect(driver.completions.count == 1)
        driver.releaseCompletion()
    }

    @Test @MainActor func render_height_uses_outer_width_and_rejects_stale_width_and_session() throws {
        let driver = ManualTranscriptGeometryDrivers()
        let scrollController = TranscriptScrollController()
        let controller = NSHostingController(rootView: transcriptView(
            revision: 1,
            bottomInset: 20,
            scrollController: scrollController,
            driver: driver,
            sessionID: "session-one",
            heightAuthority: .versionedRender
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(window: window, controller: controller)
        let collection = try #require(descendant(
            of: NativeTranscriptCollectionNSView.self,
            in: controller.view
        ))
        let scrollView = try #require(collection.enclosingScrollView)
        controller.view.frame = window.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: 1_000, height: 320)
        scrollView.frame = controller.view.bounds
        scrollView.contentView.frame = scrollView.bounds
        collection.frame = NSRect(x: 0, y: 0, width: 1_000, height: 320)
        driver.releasePreparation()
        driver.releasePreparation()

        let coordinator = try #require(
            collection.delegate as? NativeTranscriptCollectionView.Coordinator
        )
        let outerWidth = try #require(coordinator.pendingGeometryEffectiveWidth)
        let innerWidth: CGFloat = 420
        #expect(innerWidth != outerWidth)
        let value = NativeTranscriptRenderHeightValue(
            key: .init(
                contentVersion: 1,
                renderPublicationVersion: 1,
                effectiveWidth: innerWidth
            ),
            height: 70
        )
        #expect(!coordinator.acceptRenderHeight(
            value,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: outerWidth - 100,
                sessionID: "session-one"
            )
        ))
        #expect(coordinator.acceptRenderHeight(
            value,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: outerWidth,
                sessionID: "session-one"
            )
        ))
        driver.drainAll()
        #expect(collection.numberOfItems(inSection: 0) == 1)

        controller.rootView = transcriptView(
            revision: 1,
            bottomInset: 20,
            scrollController: scrollController,
            driver: driver,
            sessionID: "session-two",
            heightAuthority: .versionedRender
        )
        layout(window: window, controller: controller)
        #expect(!coordinator.acceptRenderHeight(
            value,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: outerWidth,
                sessionID: "session-one"
            )
        ))
        #expect(coordinator.acceptRenderHeight(
            value,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: outerWidth,
                sessionID: "session-two"
            )
        ))
        driver.drainAll()
        #expect(coordinator.geometryMutationCount == 2)
        #expect(coordinator.geometryCompletionCount == 2)
    }
#endif

    private func target(
        sourceRevision: Int,
        bottomInset: CGFloat = 40,
        viewportRevision: Int = 1,
        viewportMode: TranscriptGeometryViewportMode = .followTail,
        renderPublication: Int? = 1
    ) -> TranscriptGeometryTarget {
        let output = item("output", revision: sourceRevision, authority: .versionedRender)
        let sizes: [String: TranscriptGeometryItemSize]
        if let renderPublication {
            sizes = ["output": size(
                sourceRevision: sourceRevision,
                contentVersion: sourceRevision,
                publication: renderPublication,
                width: 400
            )]
        } else {
            sizes = [:]
        }
        return TranscriptGeometryTarget(
            items: [output],
            sizes: sizes,
            bottomInset: bottomInset,
            effectiveWidth: 400,
            viewportIntent: .init(revision: viewportRevision, mode: viewportMode)
        )
    }

    private func item(
        _ id: String,
        revision: Int,
        authority: NativeTranscriptHeightAuthority
    ) -> TranscriptGeometryItem {
        TranscriptGeometryItem(
            id: id,
            contentRevision: revision,
            layoutRevision: 0,
            heightAuthority: authority
        )
    }

    private func size(
        sourceRevision: Int,
        contentVersion: Int,
        publication: Int,
        width: CGFloat
    ) -> TranscriptGeometryItemSize {
        TranscriptGeometryItemSize(
            itemID: "output",
            contentRevision: sourceRevision,
            layoutRevision: 0,
            contentVersion: contentVersion,
            renderPublicationVersion: publication,
            effectiveWidth: width,
            height: 80
        )
    }

#if os(macOS)
    @MainActor
    private func transcriptView(
        revision: Int,
        bottomInset: CGFloat,
        scrollController: TranscriptScrollController,
        driver: ManualTranscriptGeometryDrivers,
        sessionID: String = "session",
        heightAuthority: NativeTranscriptHeightAuthority = .synchronousHosting
    ) -> NativeTranscriptCollectionView {
        NativeTranscriptCollectionView(
            items: [NativeTranscriptItem(
                id: "row",
                contentRevision: revision,
                heightAuthority: heightAuthority
            )],
            sessionID: sessionID,
            outputRevision: "output-\(revision)",
            bottomInset: bottomInset,
            scrollController: scrollController,
            geometryDrivers: driver.value
        ) { _ in
            AnyView(Text("Revision \(revision)\n" + String(repeating: "line\n", count: revision)))
        }
    }

    @MainActor
    private func layout(
        window: NSWindow,
        controller: NSHostingController<NativeTranscriptCollectionView>
    ) {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func descendant<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }
#endif
}

#if os(macOS)
@MainActor
private final class ManualTranscriptGeometryDrivers {
    private(set) var preparations: [@MainActor () -> Void] = []
    private(set) var mutations: [@MainActor () -> Void] = []
    private(set) var completions: [@MainActor () -> Void] = []

    var value: NativeTranscriptGeometryDrivers {
        NativeTranscriptGeometryDrivers(
            preparation: { [weak self] action in self?.preparations.append(action) },
            mutation: { [weak self] action in self?.mutations.append(action) },
            completion: { [weak self] action in self?.completions.append(action) }
        )
    }

    func releasePreparation() {
        guard !preparations.isEmpty else { return }
        preparations.removeFirst()()
    }

    func releaseMutation() {
        guard !mutations.isEmpty else { return }
        mutations.removeFirst()()
    }

    func releaseCompletion() {
        guard !completions.isEmpty else { return }
        completions.removeFirst()()
    }

    func drainAll() {
        for _ in 0..<20 {
            if !preparations.isEmpty { releasePreparation(); continue }
            if !mutations.isEmpty { releaseMutation(); continue }
            if !completions.isEmpty { releaseCompletion(); continue }
            return
        }
    }
}
#endif
