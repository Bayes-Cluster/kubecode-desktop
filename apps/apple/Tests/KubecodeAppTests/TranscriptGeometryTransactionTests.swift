import Foundation
import Testing
import KubecodeMarkdown
import KubecodeMacUI
#if os(macOS)
import AppKit
import SwiftUI
@testable import KubecodeApp
import KubecodeUI
#endif

@Suite
struct TranscriptGeometryTransactionTests {
    @Test func bursty_width_observations_begin_only_the_latest_generation() throws {
        var state = TranscriptWidthSettlementState(initialEffectiveWidth: 600)

        let firstAValue = state.observe(effectiveWidth: 800)
        let firstA = try #require(firstAValue)
        let bValue = state.observe(effectiveWidth: 720)
        let b = try #require(bValue)
        let latestAValue = state.observe(effectiveWidth: 800)
        let latestA = try #require(latestAValue)

        #expect(firstA.generation < b.generation)
        #expect(b.generation < latestA.generation)
        #expect(firstA.effectiveWidth == latestA.effectiveWidth)
        #expect(state.active == nil)
        #expect(state.pending == latestA)
        #expect(state.retainedTargetCount == 1)
        let duplicate = state.observe(effectiveWidth: 800)
        #expect(duplicate == nil)

        let staleFirst = state.beginPending(expectedGeneration: firstA.generation)
        let staleSecond = state.beginPending(expectedGeneration: b.generation)
        let beganLatest = state.beginPending(expectedGeneration: latestA.generation)
        #expect(staleFirst == nil)
        #expect(staleSecond == nil)
        #expect(beganLatest == latestA)
        #expect(state.active == latestA)
        #expect(state.pending == nil)
        #expect(state.retainedTargetCount == 1)
    }

    @Test func active_width_keeps_only_one_replaceable_latest_and_rejects_stale_completion() throws {
        var state = TranscriptWidthSettlementState(initialEffectiveWidth: 600)
        let activeValue = state.observe(effectiveWidth: 760)
        let active = try #require(activeValue)
        let beganActive = state.beginPending(expectedGeneration: active.generation)
        #expect(beganActive == active)

        let obsoleteValue = state.observe(effectiveWidth: 680)
        let obsolete = try #require(obsoleteValue)
        let latestValue = state.observe(effectiveWidth: 540)
        let latest = try #require(latestValue)
        #expect(state.active == active)
        #expect(state.pending == latest)
        #expect(state.pending != obsolete)
        #expect(state.retainedTargetCount == 2)

        let beforeStale = state
        let acceptedStale = state.complete(generation: obsolete.generation)
        #expect(!acceptedStale)
        #expect(state == beforeStale)
        let acceptedActive = state.complete(generation: active.generation)
        #expect(acceptedActive)
        #expect(state.committed.effectiveWidth == active.effectiveWidth)
        #expect(state.active == nil)
        #expect(state.pending == latest)

        let beganLatest = state.beginPending(expectedGeneration: latest.generation)
        #expect(beganLatest == latest)
        let rejectedOld = state.reject(generation: active.generation)
        #expect(!rejectedOld)
        #expect(state.active == latest)
        let rejectedLatest = state.reject(generation: latest.generation)
        #expect(rejectedLatest)
        #expect(state.committed.effectiveWidth == active.effectiveWidth)
        #expect(state.active == nil)
    }

    @Test func disclosure_geometry_is_latest_only_behind_an_active_streaming_transaction() throws {
        var state = TranscriptGeometryTransactionState(committed: disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 1,
            expanded: false
        ))

        _ = state.submit(disclosureTarget(
            sourceRevision: 2,
            disclosureRevision: 1,
            expanded: false
        ))
        let streamingValue = state.beginIfReady()
        let streaming = try #require(streamingValue)
        #expect(streaming.target.disclosures.presentation(for: "working")?.isExpanded == false)

        #expect(state.submit(disclosureTarget(
            sourceRevision: 2,
            disclosureRevision: 2,
            expanded: true
        )) == 2)
        #expect(state.submit(disclosureTarget(
            sourceRevision: 3,
            disclosureRevision: 2,
            expanded: true
        )) == 3)
        #expect(state.pending?.disclosures.presentation(for: "working")?.isExpanded == true)
        #expect(state.beginIfReady() == nil)

        let streamingCompletion = state.complete(
            transactionGeneration: streaming.generation,
            completionProvenance: streaming.completionProvenance,
            currentUserIntentRevision: 1
        )
        #expect(streamingCompletion.viewportEffect == nil)
        let disclosureValue = state.beginIfReady()
        let disclosure = try #require(disclosureValue)
        #expect(disclosure.intentGeneration == 3)
        #expect(disclosure.target.items.map(\.id) == ["working", "working-details"])
        #expect(disclosure.target.disclosures.presentation(for: "working")?.isExpanded == true)
        #expect(disclosure.target.items.first?.contentRevision == 3)
    }

    @Test func disclosure_completion_requires_exact_session_content_width_and_generation() throws {
        let collapsed = disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 1,
            expanded: false
        )
        let expanded = disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 2,
            expanded: true
        )
        var state = TranscriptGeometryTransactionState(committed: collapsed)
        _ = state.submit(expanded)
        let transactionValue = state.beginIfReady()
        let transaction = try #require(transactionValue)

        let wrongSession = TranscriptGeometryCompletionProvenance(
            sessionID: "old-session",
            items: transaction.target.items,
            sizes: transaction.target.sizes,
            effectiveWidth: transaction.target.effectiveWidth,
            disclosures: transaction.target.disclosures
        )
        let wrongWidth = TranscriptGeometryCompletionProvenance(
            sessionID: "session",
            items: transaction.target.items,
            sizes: transaction.target.sizes,
            effectiveWidth: 600,
            disclosures: transaction.target.disclosures
        )
        var wrongContentItems = transaction.target.items
        wrongContentItems[0] = TranscriptGeometryItem(
            id: wrongContentItems[0].id,
            contentRevision: wrongContentItems[0].contentRevision + 1,
            layoutRevision: wrongContentItems[0].layoutRevision,
            heightAuthority: wrongContentItems[0].heightAuthority
        )
        let wrongContent = TranscriptGeometryCompletionProvenance(
            sessionID: "session",
            items: wrongContentItems,
            sizes: transaction.target.sizes,
            effectiveWidth: transaction.target.effectiveWidth,
            disclosures: transaction.target.disclosures
        )
        var oldDisclosures = transaction.target.disclosures
        let replaced = oldDisclosures.replace(.init(
            id: "working",
            ownerItemID: "working",
            revision: 1,
            isExpanded: false
        ))
        #expect(replaced)
        let oldDisclosure = TranscriptGeometryCompletionProvenance(
            sessionID: "session",
            items: transaction.target.items,
            sizes: transaction.target.sizes,
            effectiveWidth: transaction.target.effectiveWidth,
            disclosures: oldDisclosures
        )

        for incompatible in [wrongSession, wrongContent, wrongWidth, oldDisclosure] {
            #expect(state.complete(
                transactionGeneration: transaction.generation,
                completionProvenance: incompatible,
                currentUserIntentRevision: 1
            ) == .stale)
            #expect(state.inFlight?.generation == transaction.generation)
        }
        #expect(state.complete(
            transactionGeneration: transaction.generation,
            completionProvenance: transaction.completionProvenance,
            currentUserIntentRevision: 1
        ).accepted)
        #expect(state.submit(expanded) == nil)
    }

    @Test func disclosure_targets_require_unique_ids_and_existing_owner_rows() {
        let valid = disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 1,
            expanded: false
        )
        let presentation = valid.disclosures.presentations[0]
        let duplicate = TranscriptGeometryTarget(
            items: valid.items,
            sizes: valid.sizes,
            bottomInset: valid.bottomInset,
            effectiveWidth: valid.effectiveWidth,
            viewportIntent: valid.viewportIntent,
            sessionID: valid.sessionID,
            disclosures: TranscriptDisclosureGeometryState(
                presentations: [presentation, presentation]
            )
        )
        let missingOwner = TranscriptGeometryTarget(
            items: valid.items,
            sizes: valid.sizes,
            bottomInset: valid.bottomInset,
            effectiveWidth: valid.effectiveWidth,
            viewportIntent: valid.viewportIntent,
            sessionID: valid.sessionID,
            disclosures: TranscriptDisclosureGeometryState(presentations: [.init(
                id: presentation.id,
                ownerItemID: "missing",
                revision: presentation.revision,
                isExpanded: presentation.isExpanded
            )])
        )
        let staleRevision = TranscriptGeometryTarget(
            items: valid.items,
            sizes: valid.sizes,
            bottomInset: valid.bottomInset,
            effectiveWidth: valid.effectiveWidth,
            viewportIntent: valid.viewportIntent,
            sessionID: valid.sessionID,
            disclosures: TranscriptDisclosureGeometryState(presentations: [.init(
                id: presentation.id,
                ownerItemID: presentation.ownerItemID,
                revision: presentation.revision + 1,
                isExpanded: presentation.isExpanded
            )])
        )

        #expect(!duplicate.hasValidDisclosureProvenance)
        #expect(!missingOwner.hasValidDisclosureProvenance)
        #expect(!staleRevision.hasValidDisclosureProvenance)
        var state = TranscriptGeometryTransactionState(committed: valid)
        #expect(state.submit(duplicate) == nil)
        #expect(state.submit(missingOwner) == nil)
        #expect(state.submit(staleRevision) == nil)
    }

    @Test func nested_tool_disclosure_invalidates_exactly_the_owning_details_row() {
        let collapsed = disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 1,
            expanded: true,
            nestedToolExpanded: false
        )
        let expanded = disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 2,
            expanded: true,
            nestedToolExpanded: true
        )

        let plan = TranscriptGeometryMutationPlan.between(
            previous: collapsed,
            current: expanded
        )
        #expect(!plan.reloadsAllItems)
        #expect(plan.changedIDs == ["working-details"])
        #expect(plan.insertedIDs.isEmpty)
        #expect(plan.deletedIDs.isEmpty)
    }

    @Test func unrelated_streaming_targets_retain_the_latest_user_disclosure_intent() throws {
        var state = TranscriptGeometryTransactionState(committed: disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 1,
            expanded: false
        ))
        _ = state.submit(disclosureTarget(
            sourceRevision: 1,
            disclosureRevision: 2,
            expanded: true
        ))
        let disclosureValue = state.beginIfReady()
        let disclosure = try #require(disclosureValue)
        _ = state.submit(disclosureTarget(
            sourceRevision: 2,
            disclosureRevision: 2,
            expanded: true
        ))

        _ = state.complete(
            transactionGeneration: disclosure.generation,
            completionProvenance: disclosure.completionProvenance,
            currentUserIntentRevision: 1
        )
        let streamingValue = state.beginIfReady()
        let streaming = try #require(streamingValue)
        #expect(streaming.target.disclosures.presentation(for: "working")?.isExpanded == true)
        #expect(streaming.target.items.map(\.id) == ["working", "working-details"])
    }

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
            completionProvenance: first.completionProvenance,
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
            completionProvenance: transaction.completionProvenance,
            currentUserIntentRevision: 1
        )
        #expect(stale == .stale)
        #expect(state.inFlight?.generation == transaction.generation)

        _ = state.submit(target(sourceRevision: 3, viewportRevision: 2))
        let old = state.complete(
            transactionGeneration: transaction.generation,
            completionProvenance: transaction.completionProvenance,
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
            completionProvenance: first.completionProvenance,
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
        #expect(active.target.viewportIntent.mode == .followTail)

        _ = state.submit(target(sourceRevision: 2, renderPublication: 3))
        #expect(state.beginIfReady() == nil)
        let activeCompletion = state.complete(
            transactionGeneration: active.generation,
            completionProvenance: active.completionProvenance,
            currentUserIntentRevision: 1
        )
        #expect(activeCompletion.viewportEffect == nil)

        let settlementValue = state.beginIfReady()
        let settlement = try #require(settlementValue)
        #expect(settlement.target.sizes["output"]?.renderPublicationVersion == 3)
        let settlementCompletion = state.complete(
            transactionGeneration: settlement.generation,
            completionProvenance: settlement.completionProvenance,
            currentUserIntentRevision: 1
        )
        #expect(settlementCompletion.viewportEffect == .followTail)

        let anchor = TranscriptGeometryAnchor(itemID: "output", offset: 17)
        var anchored = TranscriptGeometryTransactionState(committed: target(
            sourceRevision: 2,
            viewportRevision: 4,
            viewportMode: .preserve(anchor),
            renderPublication: 2
        ))
        _ = anchored.submit(target(
            sourceRevision: 2,
            viewportRevision: 4,
            viewportMode: .preserve(anchor),
            renderPublication: 3
        ))
        let anchoredSettlementValue = anchored.beginIfReady()
        let anchoredSettlement = try #require(anchoredSettlementValue)
        let anchoredCompletion = anchored.complete(
            transactionGeneration: anchoredSettlement.generation,
            completionProvenance: anchoredSettlement.completionProvenance,
            currentUserIntentRevision: 4
        )
        #expect(anchoredCompletion.viewportEffect == .preserve(anchor))
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
    @Test @MainActor func mounted_markdown_selection_suspends_follow_tail_until_existing_policy_resolves() throws {
        let driver = ManualTranscriptGeometryDrivers()
        let scrollController = TranscriptScrollController()
        let source = String(repeating: "Selectable native Markdown line.\n", count: 40)
        let snapshot = StreamingMarkdownSession.PreparedSnapshot(
            source: source,
            generation: 1,
            contentVersion: 1,
            document: StreamingMarkdownDocument(source: source)
        )
        let commit = AgentMarkdownRenderCommit.prepare(
            snapshot: snapshot,
            previous: nil,
            typography: WorkspaceTypography(fontName: "System", pointSize: 14),
            tone: .primary
        )
        let controller = NSHostingController(rootView: selectionTranscriptView(
            source: source,
            commit: commit,
            scrollController: scrollController,
            driver: driver
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 180),
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
        let mountedFrame = NSRect(x: 0, y: 0, width: 640, height: 180)
        controller.view.frame = mountedFrame
        scrollView.frame = controller.view.bounds
        scrollView.contentView.frame = scrollView.bounds
        collection.frame = mountedFrame
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        for _ in 0..<4 {
            controller.view.frame = mountedFrame
            scrollView.frame = controller.view.bounds
            scrollView.contentView.frame = scrollView.bounds
            collection.frame = mountedFrame
            layout(window: window, controller: controller)
            driver.drainAll()
        }
        layout(window: window, controller: controller)

        let coordinator = try #require(
            collection.delegate as? NativeTranscriptCollectionView.Coordinator
        )
        let mountedItem = coordinator.collectionView(
            collection,
            itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)
        )
        mountedItem.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        mountedItem.view.layoutSubtreeIfNeeded()
        let textView = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: mountedItem.view
        ))
        let selected = NSRange(location: 0, length: 10)

        textView.setSelectedRange(selected)
        #expect(coordinator.activeSelectionInteractionCount == 1)
        #expect(!scrollController.followsOutput)
        _ = scrollController.outputDidChange()
        #expect(scrollController.hasUnseenOutput)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: TranscriptScrollGeometry(
            documentHeight: scrollView.documentView?.bounds.height ?? 0,
            viewportHeight: scrollView.documentVisibleRect.height,
            bottomObstructionHeight: scrollView.contentInsets.bottom
        ).maximumOriginY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(coordinator.activeSelectionInteractionCount == 0)
        #expect(scrollController.followsOutput)

        collection.setFrameSize(NSSize(width: collection.frame.width, height: 1_400))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollController.viewportDidChange(isNearBottom: false)
        textView.setSelectedRange(selected)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(coordinator.activeSelectionInteractionCount == 0)
        #expect(!scrollController.followsOutput)
    }

    @Test @MainActor func mounted_disclosure_chrome_children_height_and_anchor_commit_together() throws {
        let driver = ManualTranscriptGeometryDrivers()
        let scrollController = TranscriptScrollController()
        let controller = NSHostingController(rootView: disclosureTranscriptView(
            outerExpanded: false,
            outerRevision: 1,
            nestedExpanded: false,
            nestedRevision: 1,
            scrollController: scrollController,
            driver: driver
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
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
        let mountedFrame = NSRect(x: 0, y: 0, width: 640, height: 220)
        controller.view.frame = mountedFrame
        scrollView.frame = controller.view.bounds
        scrollView.layoutSubtreeIfNeeded()
        collection.frame = mountedFrame
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        for _ in 0..<4 {
            controller.view.frame = mountedFrame
            scrollView.frame = controller.view.bounds
            scrollView.contentView.frame = scrollView.bounds
            collection.frame = mountedFrame
            layout(window: window, controller: controller)
            driver.drainAll()
        }
        layout(window: window, controller: controller)
        let coordinator = try #require(
            collection.delegate as? NativeTranscriptCollectionView.Coordinator
        )
        try #require(collection.numberOfItems(inSection: 0) == 1)
        #expect(coordinator.committedDisclosurePresentation(id: "working")?.isExpanded == false)
        let initialHeader = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)
        ))
        let headerOffset = initialHeader.frame.minY - scrollView.documentVisibleRect.minY

        controller.rootView = disclosureTranscriptView(
            outerExpanded: true,
            outerRevision: 2,
            nestedExpanded: false,
            nestedRevision: 1,
            scrollController: scrollController,
            driver: driver
        )
        layout(window: window, controller: controller)
        driver.releasePreparation()
        #expect(coordinator.committedDisclosurePresentation(id: "working")?.isExpanded == false)
        #expect(collection.numberOfItems(inSection: 0) == 1)
        #expect(driver.mutations.count == 1)
        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(coordinator.committedDisclosurePresentation(id: "working")?.isExpanded == true)
        #expect(collection.numberOfItems(inSection: 0) == 2)
        let expandedDetailsSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 1, section: 0)
        )
        #expect(expandedDetailsSize.height > 20)
        driver.releaseCompletion()
        layout(window: window, controller: controller)
        let expandedHeader = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)
        ))
        #expect(abs(
            expandedHeader.frame.minY - scrollView.documentVisibleRect.minY - headerOffset
        ) <= 1)

        controller.rootView = disclosureTranscriptView(
            outerExpanded: true,
            outerRevision: 2,
            nestedExpanded: true,
            nestedRevision: 2,
            scrollController: scrollController,
            driver: driver
        )
        layout(window: window, controller: controller)
        driver.releasePreparation()
        #expect(coordinator.committedDisclosurePresentation(id: "tool:tool-1")?.isExpanded == false)
        let collapsedToolSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 1, section: 0)
        )
        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(coordinator.lastReconfiguredItemIDs == ["working-details"])
        #expect(coordinator.committedDisclosurePresentation(id: "tool:tool-1")?.isExpanded == true)
        let expandedToolSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 1, section: 0)
        )
        #expect(expandedToolSize.height > collapsedToolSize.height)
        let headerFrame = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)
        )).frame
        let detailsFrame = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 1, section: 0)
        )).frame
        #expect(headerFrame.maxY <= detailsFrame.minY)
        driver.releaseCompletion()

        controller.rootView = disclosureTranscriptView(
            outerExpanded: false,
            outerRevision: 3,
            nestedExpanded: true,
            nestedRevision: 2,
            scrollController: scrollController,
            driver: driver
        )
        layout(window: window, controller: controller)
        driver.releasePreparation()
        #expect(collection.numberOfItems(inSection: 0) == 2)
        #expect(coordinator.committedDisclosurePresentation(id: "working")?.isExpanded == true)
        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(collection.numberOfItems(inSection: 0) == 1)
        #expect(coordinator.committedDisclosurePresentation(id: "working")?.isExpanded == false)
        driver.releaseCompletion()
        layout(window: window, controller: controller)
        let collapsedHeader = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)
        ))
        #expect(abs(
            collapsedHeader.frame.minY - scrollView.documentVisibleRect.minY - headerOffset
        ) <= 1)
    }

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

    @Test @MainActor func mounted_width_burst_commits_only_latest_and_preserves_away_anchor() throws {
        let driver = ManualTranscriptGeometryDrivers()
        let scrollController = TranscriptScrollController()
        let controller = NSHostingController(rootView: widthTranscriptView(
            scrollController: scrollController,
            driver: driver
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 240),
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
        scrollView.scrollerStyle = .overlay
        controller.view.frame = window.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: 720, height: 240)
        scrollView.frame = controller.view.bounds
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.frame = scrollView.bounds
        collection.frame = NSRect(x: 0, y: 0, width: 720, height: 240)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        for _ in 0..<4 {
            controller.view.frame = window.contentView?.bounds
                ?? NSRect(x: 0, y: 0, width: 720, height: 240)
            scrollView.frame = controller.view.bounds
            scrollView.contentView.frame = scrollView.bounds
            collection.frame = NSRect(x: 0, y: 0, width: 720, height: 240)
            layout(window: window, controller: controller)
            driver.drainAll()
        }
        layout(window: window, controller: controller)
        collection.collectionViewLayout?.invalidateLayout()
        collection.layoutSubtreeIfNeeded()

        let coordinator = try #require(
            collection.delegate as? NativeTranscriptCollectionView.Coordinator
        )
        try #require(collection.numberOfItems(inSection: 0) == 3)
        let anchorAttributes = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)
        ))
        let initialScrollGeometry = TranscriptScrollGeometry(
            documentHeight: scrollView.documentView?.bounds.height ?? 0,
            viewportHeight: scrollView.documentVisibleRect.height,
            bottomObstructionHeight: scrollView.contentInsets.bottom
        )
        #expect(initialScrollGeometry.maximumOriginY > 0)
        let initialAnchorMinY = anchorAttributes.frame.minY
        let origin = initialScrollGeometry.clampedOriginY(100)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollController.viewportDidChange(isNearBottom: false)
        let anchor = TranscriptGeometryAnchor(
            itemID: "width-row-0",
            offset: initialAnchorMinY - scrollView.documentVisibleRect.minY
        )
        driver.viewportAnchor = anchor
        let initialSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )
        let initialMutationCount = coordinator.geometryMutationCount
        let initialCompletionCount = coordinator.geometryCompletionCount

        for width in [900.0, 640.0, 840.0] {
            controller.view.frame.size.width = width
            scrollView.frame = controller.view.bounds
            scrollView.contentView.frame = scrollView.bounds
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        let latestWidth = try #require(driver.pendingWidthSettlementTarget)
        #expect(driver.canceledWidthSettlementCount >= 2)
        #expect(driver.preparations.isEmpty)
        #expect(driver.mutations.isEmpty)
        #expect(coordinator.pendingWidthSettlement == latestWidth)
        #expect(coordinator.pendingGeometryEffectiveWidth == latestWidth.effectiveWidth)

        driver.releaseCanceledWidthSettlement()
        #expect(driver.preparations.isEmpty)
        #expect(driver.mutations.isEmpty)
        #expect(coordinator.geometryMutationCount == initialMutationCount)
        #expect(coordinator.geometryCompletionCount == initialCompletionCount)
        #expect(coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        ) == initialSize)

        driver.releaseWidthSettlement()
        #expect(driver.preparations.count == 1)
        driver.releasePreparation()
        #expect(driver.mutations.count == 1)
        #expect(coordinator.inFlightGeometryGeneration != nil)
        #expect(coordinator.activeWidthSettlement == latestWidth)
        #expect(coordinator.geometryMutationCount == initialMutationCount)

        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(driver.completions.count == 1)
        #expect(coordinator.geometryMutationCount == initialMutationCount + 1)
        let settledSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )
        #expect(settledSize.width == latestWidth.effectiveWidth)
        let sectionInset = try #require(
            collection.collectionViewLayout as? NSCollectionViewFlowLayout
        ).sectionInset
        #expect(settledSize.width < collection.frame.width - sectionInset.left - sectionInset.right)

        driver.releaseCompletion()
        #expect(coordinator.inFlightGeometryGeneration == nil)
        #expect(coordinator.pendingWidthSettlement == nil)
        #expect(coordinator.activeWidthSettlement == nil)
        #expect(coordinator.geometryCompletionCount == initialCompletionCount + 1)
        let settledAnchor = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)
        ))
        let anchorDelta = settledAnchor.frame.minY
            - scrollView.documentVisibleRect.minY
            - anchor.offset
        #expect(abs(anchorDelta) <= 1)
        #expect(!scrollController.followsOutput)

        let frameAfterCommit = collection.frame
        let originAfterCommit = scrollView.documentVisibleRect.origin
        driver.releaseCanceledWidthSettlement()
        #expect(collection.frame == frameAfterCommit)
        #expect(scrollView.documentVisibleRect.origin == originAfterCommit)
        #expect(coordinator.geometryMutationCount == initialMutationCount + 1)
        #expect(coordinator.geometryCompletionCount == initialCompletionCount + 1)
        #expect(driver.preparations.isEmpty)
        #expect(driver.mutations.isEmpty)
        #expect(driver.completions.isEmpty)
    }

    @Test @MainActor func mounted_width_only_commit_reuses_markdown_session_commit_and_text_storage() async throws {
        let driver = ManualTranscriptGeometryDrivers()
        let scrollController = TranscriptScrollController()
        let counter = GeometryMarkdownDocumentBuildCounter()
        let store = AgentMarkdownRenderStore(documentBuilder: counter.build)
        let source = String(repeating: "A wrapping **Markdown** response. ", count: 20)
        let identity = AgentMarkdownRenderIdentity(
            scope: .init(projectIdentity: nil, sessionID: "mounted-attachment"),
            rowID: "markdown",
            segment: .standalone
        )
        let controller = NSHostingController(rootView: markdownTranscriptView(
            source: source,
            revision: 1,
            store: store,
            scrollController: scrollController,
            driver: driver
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
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
        scrollView.scrollerStyle = .overlay
        controller.view.frame = window.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: 640, height: 240)
        scrollView.frame = controller.view.bounds
        scrollView.contentView.frame = scrollView.bounds
        collection.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        layout(window: window, controller: controller)

        try await waitForGeometry("initial Markdown preparation") {
            !driver.preparations.isEmpty
        }
        driver.releasePreparation()
        try await drivePreparationsUntilMutation(
            driver: driver,
            window: window,
            controller: controller
        )
        driver.releaseMutation()
        layout(window: window, controller: controller)
        driver.releaseCompletion()
        layout(window: window, controller: controller)
        let coordinator = try #require(
            collection.delegate as? NativeTranscriptCollectionView.Coordinator
        )
        let mountedItem = coordinator.collectionView(
            collection,
            itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)
        )
        let mountedSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )
        mountedItem.view.frame = NSRect(origin: .zero, size: mountedSize)
        controller.view.addSubview(mountedItem.view)
        mountedItem.view.layoutSubtreeIfNeeded()
        try await waitForGeometry("visible Markdown host") {
            mountedItem.view.layoutSubtreeIfNeeded()
            return descendant(
                of: NativeAgentMarkdownTextView.self,
                in: mountedItem.view
            ) != nil
        }

        let textView = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: mountedItem.view
        ))
        let textStorage = try #require(textView.textStorage)
        let session = try #require(store.testingSession(identity: identity))
        let commit = try #require(store.latestRenderCommit(identity: identity))
        let parseCount = counter.count
        let preparationCount = session.preparationCount
        let measurementCount = store.testingMeasurementCount
        let initialMutationCount = coordinator.geometryMutationCount
        let initialCompletionCount = coordinator.geometryCompletionCount

        controller.view.frame.size.width = 800
        scrollView.frame = controller.view.bounds
        scrollView.contentView.frame = scrollView.bounds
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        let widthTarget = try #require(driver.pendingWidthSettlementTarget)
        #expect(driver.preparations.isEmpty)
        driver.releaseWidthSettlement()
        try await drivePreparationsUntilMutation(
            driver: driver,
            window: window,
            controller: controller
        )
        driver.releaseMutation()
        layout(window: window, controller: controller)
        driver.releaseCompletion()
        let settledMountedSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )
        mountedItem.view.frame.size = settledMountedSize
        mountedItem.view.layoutSubtreeIfNeeded()

        let settledTextView = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: mountedItem.view
        ))
        #expect(coordinator.activeWidthSettlement == nil)
        #expect(coordinator.pendingWidthSettlement == nil)
        #expect(coordinator.desiredWidthSettlement == widthTarget)
        #expect(coordinator.geometryMutationCount == initialMutationCount + 1)
        #expect(coordinator.geometryCompletionCount == initialCompletionCount + 1)
        #expect(store.testingSession(identity: identity) === session)
        #expect(store.latestRenderCommit(identity: identity) === commit)
        #expect(counter.count == parseCount)
        #expect(session.preparationCount == preparationCount)
        #expect(store.testingMeasurementCount > measurementCount)
        #expect(settledTextView === textView)
        #expect(settledTextView.textStorage === textStorage)
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
            completionProvenance: tail.completionProvenance,
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
            completionProvenance: away.completionProvenance,
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
        let initialFrame = NSRect(x: 0, y: 0, width: 820, height: 320)
        controller.view.frame = initialFrame
        scrollView.frame = controller.view.bounds
        scrollView.contentView.frame = scrollView.bounds
        collection.frame = initialFrame
        driver.releaseWidthSettlement()
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

        let oldOuterWidth = outerWidth
        let resizedFrame = NSRect(x: 0, y: 0, width: 1_000, height: 320)
        controller.view.frame = resizedFrame
        scrollView.frame = resizedFrame
        scrollView.contentView.frame = scrollView.bounds
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        layout(window: window, controller: controller)
        driver.releaseWidthSettlement()
        driver.releasePreparation()
        let resizedOuterWidth = try #require(coordinator.pendingGeometryEffectiveWidth)
        let resizedWidthGeneration = coordinator.desiredWidthSettlement.generation
        #expect(resizedOuterWidth != oldOuterWidth)
        let lower = NativeTranscriptRenderHeightValue(
            key: .init(
                contentVersion: 0,
                renderPublicationVersion: 9,
                effectiveWidth: innerWidth
            ),
            height: 60
        )
        #expect(!coordinator.acceptRenderHeight(
            lower,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: resizedOuterWidth,
                widthGeneration: resizedWidthGeneration,
                sessionID: "session-one"
            )
        ))
        #expect(coordinator.acceptRenderHeight(
            value,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: resizedOuterWidth,
                widthGeneration: resizedWidthGeneration,
                sessionID: "session-one"
            )
        ))
        #expect(!coordinator.acceptRenderHeight(
            value,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: resizedOuterWidth,
                widthGeneration: resizedWidthGeneration,
                sessionID: "session-one"
            )
        ))
        #expect(!coordinator.acceptRenderHeight(
            NativeTranscriptRenderHeightValue(
                key: .init(
                    contentVersion: 1,
                    renderPublicationVersion: 2,
                    effectiveWidth: innerWidth
                ),
                height: 80
            ),
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: oldOuterWidth,
                sessionID: "session-one"
            )
        ))
        driver.drainAll()

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
                outerEffectiveWidth: resizedOuterWidth,
                widthGeneration: resizedWidthGeneration,
                sessionID: "session-one"
            )
        ))
        #expect(coordinator.acceptRenderHeight(
            value,
            provenance: .init(
                itemID: "row",
                contentRevision: 1,
                outerEffectiveWidth: resizedOuterWidth,
                widthGeneration: resizedWidthGeneration,
                sessionID: "session-two"
            )
        ))
        driver.drainAll()
        #expect(coordinator.geometryMutationCount == 3)
        #expect(coordinator.geometryCompletionCount == 3)
    }

    @Test @MainActor func mounted_attachment_height_queues_once_and_settles_follow_tail_or_anchor() async throws {
        try await verifyMountedAttachmentGeometry(followsOutput: true)
        try await verifyMountedAttachmentGeometry(followsOutput: false)
    }

    @MainActor
    private func verifyMountedAttachmentGeometry(followsOutput: Bool) async throws {
        let driver = ManualTranscriptGeometryDrivers()
        let scrollController = TranscriptScrollController()
        let imageData = try geometryImageData()
        _ = try #require(MarkdownRemoteImageDecoder.image(from: imageData))
        let resolver = GeometryAttachmentResolver(data: imageData)
        let store = AgentMarkdownRenderStore(attachmentResolver: { _, _ in
            await resolver.resolve()
        })
        let renderIdentity = AgentMarkdownRenderIdentity(
            scope: .init(projectIdentity: nil, sessionID: "mounted-attachment"),
            rowID: "markdown",
            segment: .standalone
        )
        let source = "Before image\n\n![pixel](asset.png)\n\nAfter image"
        let controller = NSHostingController(rootView: markdownTranscriptView(
            source: source,
            revision: 1,
            store: store,
            scrollController: scrollController,
            driver: driver
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 180),
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
            ?? NSRect(x: 0, y: 0, width: 640, height: 180)
        scrollView.frame = controller.view.bounds
        scrollView.contentView.frame = scrollView.bounds
        collection.frame = NSRect(x: 0, y: 0, width: 640, height: 180)
        layout(window: window, controller: controller)
        let coordinator = try #require(
            collection.delegate as? NativeTranscriptCollectionView.Coordinator
        )

        try await waitForGeometry("initial preparation") { !driver.preparations.isEmpty }
        driver.releasePreparation()
        try await drivePreparationsUntilMutation(
            driver: driver,
            window: window,
            controller: controller
        )
        #expect(store.latestRenderInputs(identity: renderIdentity)?.renderPublicationVersion == 1)
        #expect(driver.mutations.count == 1)
        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(driver.completions.count == 1)
        driver.releaseCompletion()
        layout(window: window, controller: controller)
        #expect(coordinator.inFlightGeometryGeneration == nil)
        collection.reloadData()
        collection.layoutSubtreeIfNeeded()
        layout(window: window, controller: controller)
        #expect(collection.numberOfItems(inSection: 0) == 2)
        #expect(collection.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)
        ) != nil)
        let mountedItem = coordinator.collectionView(
            collection,
            itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)
        )
        let mountedSize = coordinator.collectionView(
            collection,
            layout: collection.collectionViewLayout!,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )
        mountedItem.view.frame = NSRect(
            x: 0,
            y: 0,
            width: mountedSize.width,
            height: mountedSize.height
        )
        controller.view.addSubview(mountedItem.view)
        mountedItem.view.layoutSubtreeIfNeeded()
        try await waitForGeometry("visible item mount") {
            mountedItem.view.layoutSubtreeIfNeeded()
            return descendant(
                of: NativeAgentMarkdownTextView.self,
                in: mountedItem.view
            ) != nil
        }
        _ = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: mountedItem.view
        ))

        let anchorAttributes = try #require(collection.layoutAttributesForItem(
            at: IndexPath(item: 1, section: 0)
        ))
        let expectedAnchorOffset: CGFloat?
        if followsOutput {
            expectedAnchorOffset = nil
        } else {
            let origin = TranscriptScrollGeometry(
                documentHeight: scrollView.documentView?.bounds.height ?? 0,
                viewportHeight: scrollView.documentVisibleRect.height,
                bottomObstructionHeight: scrollView.contentInsets.bottom
            ).clampedOriginY(anchorAttributes.frame.minY + 30)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollController.viewportDidChange(isNearBottom: false)
            let offset = anchorAttributes.frame.minY
                - scrollView.documentVisibleRect.minY
            expectedAnchorOffset = offset
            driver.viewportAnchor = TranscriptGeometryAnchor(
                itemID: "anchor",
                offset: offset
            )
            #expect(!scrollController.followsOutput)
        }

        controller.rootView = markdownTranscriptView(
            source: source,
            revision: 1,
            store: store,
            scrollController: scrollController,
            driver: driver,
            bottomInset: 20
        )
        layout(window: window, controller: controller)
        try await drivePreparationsUntilMutation(
            driver: driver,
            window: window,
            controller: controller
        )
        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(driver.completions.count == 1)
        let activeMutationCount = coordinator.geometryMutationCount
        let initialGeneration = try #require(coordinator.inFlightGeometryGeneration)
        let unresolved = try #require(store.latestRenderInputs(identity: renderIdentity))
        #expect(await resolver.callCount == 1)

        await resolver.release(0)
        await resolver.waitForCompletion(0)
        try await waitForGeometry("attachment settlement") {
            layout(window: window, controller: controller)
            return store.latestRenderInputs(identity: renderIdentity)?.attachmentResolutionGeneration == 1
        }
        #expect(store.latestRenderInputs(identity: renderIdentity)?.attachmentResolutionGeneration == 1)
        try await drivePreparationsWhileInFlight(
            driver: driver,
            window: window,
            controller: controller,
            coordinator: coordinator
        )
        #expect(coordinator.inFlightGeometryGeneration == initialGeneration)
        #expect(driver.mutations.isEmpty)

        let countsBeforeStale = (
            mutations: coordinator.geometryMutationCount,
            completions: coordinator.geometryCompletionCount
        )
        let staleSettlement = store.settleAttachments(
            identity: renderIdentity,
            expectedRenderPublicationVersion: unresolved.renderPublicationVersion,
            images: ["asset.png": NSImage(size: NSSize(width: 32, height: 16))],
            expectedAttachmentRequestEpoch: -1
        )
        #expect(!staleSettlement)
        #expect(driver.mutations.isEmpty)
        #expect(coordinator.geometryMutationCount == countsBeforeStale.mutations)
        #expect(coordinator.geometryCompletionCount == countsBeforeStale.completions)

        driver.releaseCompletion()
        #expect(driver.mutations.count == 1)
        driver.releaseMutation()
        layout(window: window, controller: controller)
        #expect(driver.completions.count == 1)
        driver.releaseCompletion()
        layout(window: window, controller: controller)

        #expect(coordinator.geometryMutationCount == activeMutationCount + 1)
        #expect(coordinator.geometryCompletionCount == coordinator.geometryMutationCount)
        #expect(coordinator.inFlightGeometryGeneration == nil)
        if let expectedAnchorOffset {
            let settledAnchor = try #require(collection.layoutAttributesForItem(
                at: IndexPath(item: 1, section: 0)
            ))
            let settledOffset = settledAnchor.frame.minY
                - scrollView.documentVisibleRect.minY
            #expect(abs(settledOffset - expectedAnchorOffset) <= 1)
            #expect(!scrollController.followsOutput)
        } else {
            let scrollGeometry = TranscriptScrollGeometry(
                documentHeight: scrollView.documentView?.bounds.height ?? 0,
                viewportHeight: scrollView.documentVisibleRect.height,
                bottomObstructionHeight: scrollView.contentInsets.bottom
            )
            #expect(scrollGeometry.distanceFromTail(
                originY: scrollView.documentVisibleRect.origin.y
            ) <= 1)
        }

        let settled = try #require(store.latestRenderInputs(identity: renderIdentity))
        let settledMutationCount = coordinator.geometryMutationCount
        let settledCompletionCount = coordinator.geometryCompletionCount
        let duplicate = store.submit(
            identity: renderIdentity,
            source: source,
            typography: WorkspaceTypography(fontName: "System", pointSize: 14),
            tone: .primary
        )
        for _ in 0..<8 {
            await Task.yield()
            layout(window: window, controller: controller)
        }
        #expect(duplicate == .unchanged(contentVersion: settled.contentVersion))
        #expect(await resolver.callCount == 1)
        #expect(driver.preparations.isEmpty)
        #expect(driver.mutations.isEmpty)
        #expect(driver.completions.isEmpty)
        #expect(coordinator.geometryMutationCount == settledMutationCount)
        #expect(coordinator.geometryCompletionCount == settledCompletionCount)
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

    private func disclosureTarget(
        sourceRevision: Int,
        disclosureRevision: Int,
        expanded: Bool,
        nestedToolExpanded: Bool? = nil
    ) -> TranscriptGeometryTarget {
        let outerDisclosureRevision = nestedToolExpanded == nil ? disclosureRevision : 1
        let header = TranscriptGeometryItem(
            id: "working",
            contentRevision: sourceRevision,
            layoutRevision: outerDisclosureRevision,
            heightAuthority: .synchronousHosting
        )
        var items = [header]
        var sizes = [
            header.id: TranscriptGeometryItemSize(
                itemID: header.id,
                contentRevision: header.contentRevision,
                layoutRevision: header.layoutRevision,
                contentVersion: 0,
                renderPublicationVersion: 0,
                effectiveWidth: 400,
                height: 28
            ),
        ]
        var presentations = [TranscriptDisclosureGeometryPresentation(
            id: "working",
            ownerItemID: "working",
            revision: outerDisclosureRevision,
            isExpanded: expanded
        )]
        if expanded {
            let details = TranscriptGeometryItem(
                id: "working-details",
                contentRevision: sourceRevision,
                layoutRevision: nestedToolExpanded == nil ? 0 : disclosureRevision,
                heightAuthority: .synchronousHosting
            )
            items.append(details)
            sizes[details.id] = TranscriptGeometryItemSize(
                itemID: details.id,
                contentRevision: details.contentRevision,
                layoutRevision: details.layoutRevision,
                contentVersion: 0,
                renderPublicationVersion: 0,
                effectiveWidth: 400,
                height: nestedToolExpanded == true ? 180 : 64
            )
            if let nestedToolExpanded {
                presentations.append(TranscriptDisclosureGeometryPresentation(
                    id: "tool:tool-1",
                    ownerItemID: details.id,
                    revision: disclosureRevision,
                    isExpanded: nestedToolExpanded
                ))
            }
        }
        return TranscriptGeometryTarget(
            items: items,
            sizes: sizes,
            bottomInset: 40,
            effectiveWidth: 400,
            viewportIntent: .init(revision: 1, mode: .followTail),
            sessionID: "session",
            disclosures: TranscriptDisclosureGeometryState(presentations: presentations)
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
    private func widthTranscriptView(
        scrollController: TranscriptScrollController,
        driver: ManualTranscriptGeometryDrivers
    ) -> NativeTranscriptCollectionView {
        NativeTranscriptCollectionView(
            items: (0..<3).map { index in
                NativeTranscriptItem(id: "width-row-\(index)", contentRevision: 1)
            },
            sessionID: "width-session",
            outputRevision: "stable-width-output",
            bottomInset: 0,
            scrollController: scrollController,
            geometryDrivers: driver.value
        ) { index in
            AnyView(
                Text("Width row \(index)")
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            )
        }
    }

    @MainActor
    private func markdownTranscriptView(
        source: String,
        revision: Int,
        store: AgentMarkdownRenderStore,
        scrollController: TranscriptScrollController,
        driver: ManualTranscriptGeometryDrivers,
        bottomInset: CGFloat = 0
    ) -> NativeTranscriptCollectionView {
        NativeTranscriptCollectionView(
            items: [
                NativeTranscriptItem(
                    id: "markdown",
                    contentRevision: revision,
                    heightAuthority: .versionedRender
                ),
                NativeTranscriptItem(
                    id: "anchor",
                    contentRevision: 1,
                    heightAuthority: .synchronousHosting
                ),
            ],
            sessionID: "mounted-attachment",
            outputRevision: "output-\(revision)",
            bottomInset: bottomInset,
            scrollController: scrollController,
            geometryDrivers: driver.value
        ) { index in
            if index == 0 {
                return AnyView(
                    AgentMarkdownView(source: source, tone: .primary, isStreaming: true)
                        .environment(\.agentMarkdownRenderStore, store)
                        .workspaceTypography(WorkspaceTypography(fontName: "System", pointSize: 14))
                )
            }
            return AnyView(
                Text("Stable away anchor")
                    .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
            )
        }
    }

    @MainActor
    private func selectionTranscriptView(
        source: String,
        commit: AgentMarkdownRenderCommit,
        scrollController: TranscriptScrollController,
        driver: ManualTranscriptGeometryDrivers
    ) -> NativeTranscriptCollectionView {
        NativeTranscriptCollectionView(
            items: [
                NativeTranscriptItem(id: "selection-anchor", contentRevision: 1),
                NativeTranscriptItem(id: "selection", contentRevision: 1),
            ],
            sessionID: "selection-session",
            outputRevision: "selection-output",
            bottomInset: 0,
            scrollController: scrollController,
            geometryDrivers: driver.value
        ) { index in
            if index == 0 {
                return AnyView(
                    Text("Stable away-from-tail anchor")
                        .frame(maxWidth: .infinity, minHeight: 600, alignment: .topLeading)
                )
            }
            return AnyView(
                NativeSelectableAgentMarkdownView(
                    source: source,
                    typography: WorkspaceTypography(fontName: "System", pointSize: 14),
                    tone: .primary,
                    copyResponseSource: source,
                    preparedCommit: commit
                )
                .frame(maxWidth: .infinity, minHeight: 600, alignment: .topLeading)
            )
        }
    }

    @MainActor
    private func disclosureTranscriptView(
        outerExpanded: Bool,
        outerRevision: Int,
        nestedExpanded: Bool,
        nestedRevision: Int,
        scrollController: TranscriptScrollController,
        driver: ManualTranscriptGeometryDrivers
    ) -> NativeTranscriptCollectionView {
        var items = [NativeTranscriptItem(
            id: "working",
            contentRevision: 1,
            layoutRevision: outerRevision
        )]
        var presentations = [TranscriptDisclosureGeometryPresentation(
            id: "working",
            ownerItemID: "working",
            revision: outerRevision,
            isExpanded: outerExpanded
        )]
        if outerExpanded {
            items.append(NativeTranscriptItem(
                id: "working-details",
                contentRevision: 1,
                layoutRevision: nestedRevision
            ))
            presentations.append(TranscriptDisclosureGeometryPresentation(
                id: "tool:tool-1",
                ownerItemID: "working-details",
                revision: nestedRevision,
                isExpanded: nestedExpanded
            ))
        }
        return NativeTranscriptCollectionView(
            items: items,
            sessionID: "disclosure-session",
            outputRevision: "stable-output",
            bottomInset: 0,
            disclosures: TranscriptDisclosureGeometryState(presentations: presentations),
            scrollController: scrollController,
            geometryDrivers: driver.value
        ) { index in
            AnyView(GeometryDisclosureProbe(
                kind: index == 0 ? .header : .details
            ))
        }
    }

    @MainActor
    private func waitForGeometry(
        _ label: String = "geometry",
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for mounted transcript \(label)")
                return
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func drivePreparationsUntilMutation(
        driver: ManualTranscriptGeometryDrivers,
        window: NSWindow,
        controller: NSHostingController<NativeTranscriptCollectionView>
    ) async throws {
        try await waitForGeometry("ready mutation") {
            layout(window: window, controller: controller)
            if driver.pendingWidthSettlementTarget != nil {
                driver.releaseWidthSettlement()
            }
            if !driver.preparations.isEmpty { driver.releasePreparation() }
            return !driver.mutations.isEmpty
        }
    }

    @MainActor
    private func drivePreparationsWhileInFlight(
        driver: ManualTranscriptGeometryDrivers,
        window: NSWindow,
        controller: NSHostingController<NativeTranscriptCollectionView>,
        coordinator: NativeTranscriptCollectionView.Coordinator
    ) async throws {
        try await waitForGeometry("queued attachment target") {
            layout(window: window, controller: controller)
            if driver.pendingWidthSettlementTarget != nil {
                driver.releaseWidthSettlement()
            }
            if !driver.preparations.isEmpty {
                driver.releasePreparation()
                return false
            }
            return coordinator.pendingGeometryEffectiveWidth != nil
        }
    }

    private func geometryImageData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40,
            pixelsHigh: 120,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
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
private struct GeometryDisclosureProbe: View {
    enum Kind {
        case header
        case details
    }

    @Environment(\.nativeTranscriptDisclosureContext) private var disclosureContext
    let kind: Kind

    var body: some View {
        switch kind {
        case .header:
            Text(disclosureContext?.isExpanded(id: "working", fallback: false) == true
                ? "Working expanded"
                : "Working collapsed")
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        case .details:
            VStack(alignment: .leading, spacing: 4) {
                Text("Tool")
                if disclosureContext?.isExpanded(id: "tool:tool-1", fallback: false) == true {
                    ForEach(0..<12, id: \.self) { index in
                        Text("Tool output \(index)")
                    }
                } else {
                    Text("Collapsed tool")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private final class ManualTranscriptGeometryDrivers {
    private struct WidthSettlement {
        let target: TranscriptWidthSettlementTarget
        let action: @MainActor () -> Void
    }

    private(set) var preparations: [@MainActor () -> Void] = []
    private(set) var mutations: [@MainActor () -> Void] = []
    private(set) var completions: [@MainActor () -> Void] = []
    private var widthSettlement: WidthSettlement?
    private var canceledWidthSettlements: [WidthSettlement] = []
    var viewportAnchor: TranscriptGeometryAnchor?

    var pendingWidthSettlementTarget: TranscriptWidthSettlementTarget? {
        widthSettlement?.target
    }

    var canceledWidthSettlementCount: Int { canceledWidthSettlements.count }

    var value: NativeTranscriptGeometryDrivers {
        NativeTranscriptGeometryDrivers(
            preparation: { [weak self] action in self?.preparations.append(action) },
            mutation: { [weak self] action in self?.mutations.append(action) },
            completion: { [weak self] action in self?.completions.append(action) },
            widthSettlement: { [weak self] target, action in
                self?.widthSettlement = WidthSettlement(target: target, action: action)
                return { [weak self] in
                    guard let self,
                          let settlement = self.widthSettlement,
                          settlement.target == target
                    else { return }
                    self.canceledWidthSettlements.append(settlement)
                    self.widthSettlement = nil
                }
            },
            viewportAnchor: { [weak self] in self?.viewportAnchor }
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

    func releaseWidthSettlement() {
        guard let settlement = widthSettlement else { return }
        widthSettlement = nil
        settlement.action()
    }

    func releaseCanceledWidthSettlement() {
        guard !canceledWidthSettlements.isEmpty else { return }
        canceledWidthSettlements.removeFirst().action()
    }

    func drainAll() {
        for _ in 0..<20 {
            if pendingWidthSettlementTarget != nil { releaseWidthSettlement(); continue }
            if !preparations.isEmpty { releasePreparation(); continue }
            if !mutations.isEmpty { releaseMutation(); continue }
            if !completions.isEmpty { releaseCompletion(); continue }
            return
        }
    }
}

@MainActor
private final class GeometryMarkdownDocumentBuildCounter {
    private(set) var count = 0

    func build(
        source: String,
        previous: StreamingMarkdownDocument?
    ) -> StreamingMarkdownDocument {
        count += 1
        return StreamingMarkdownDocument(source: source, previous: previous)
    }
}

private actor GeometryAttachmentResolver {
    private let data: Data
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var completed: Set<Int> = []
    private var completionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var callCount = 0

    init(data: Data) {
        self.data = data
    }

    func resolve() async -> Data {
        let index = callCount
        callCount += 1
        if released.remove(index) == nil {
            await withCheckedContinuation { continuation in
                continuations[index] = continuation
            }
        }
        completed.insert(index)
        for continuation in completionWaiters.removeValue(forKey: index) ?? [] {
            continuation.resume()
        }
        return data
    }

    func waitForCompletion(_ index: Int) async {
        guard !completed.contains(index) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[index, default: []].append(continuation)
        }
    }

    func release(_ index: Int) {
        if let continuation = continuations.removeValue(forKey: index) {
            continuation.resume()
        } else {
            released.insert(index)
        }
    }
}
#endif
