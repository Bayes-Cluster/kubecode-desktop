import AppKit
import KubecodeKit
import KubecodeMarkdown
import KubecodeMacUI
import SwiftUI
import Testing
@testable import KubecodeApp

@Suite(.serialized)
struct PreparedMarkdownRendererTests {
    private let typography = WorkspaceTypography(fontName: "System", pointSize: 14)

    @Test @MainActor func render_height_key_changes_for_every_exact_layout_input() {
        let base = renderKey()

        #expect(renderKey(width: 319.4) == renderKey(width: 319.49))
        #expect(renderKey(width: 319.6) != base)
        #expect(renderKey(contentVersion: 2) != base)
        #expect(renderKey(renderPublicationVersion: 2) != base)
        #expect(renderKey(typography: .init(fontName: "System", pointSize: 15)) != base)
        #expect(renderKey(styleRevision: 2) != base)
        #expect(renderKey(tone: .secondary) != base)
        #expect(renderKey(resourceIdentity: "project-2") != base)
        #expect(renderKey(resourceGeneration: 2) != base)
        #expect(renderKey(attachmentResolutionGeneration: 2) != base)
    }

    @Test @MainActor func render_height_commit_matches_visible_content_version_and_identity() {
        let rendered = commit(
            document: StreamingMarkdownDocument(source: "Visible **value**"),
            generation: 4,
            contentVersion: 3
        )
        let measured = AgentMarkdownRenderHeightCommit.measure(
            renderCommit: rendered,
            key: renderKey(contentVersion: 3),
            verticalInset: 4
        )
        let textView = NativeAgentMarkdownTextView(frame: .zero)
        textView.textStorage?.setAttributedString(rendered.attributedValue)

        #expect(measured.renderCommit === rendered)
        #expect(measured.key.contentVersion == rendered.contentVersion)
        #expect(textView.attributedString().isEqual(to: measured.renderCommit.attributedValue))
    }

    @Test @MainActor func stale_height_publication_cannot_replace_a_newer_render_commit() {
        let old = NativeTranscriptRenderHeightValue(
            key: .init(contentVersion: 1, renderPublicationVersion: 1, effectiveWidth: 320),
            height: 40
        )
        let latest = NativeTranscriptRenderHeightValue(
            key: .init(contentVersion: 2, renderPublicationVersion: 2, effectiveWidth: 320),
            height: 80
        )

        #expect(latest.isStrictlyNewer(than: old, effectiveWidth: 320))
        #expect(!old.isStrictlyNewer(than: latest, effectiveWidth: 320))
        #expect(!latest.isStrictlyNewer(than: old, effectiveWidth: 600))
        #expect(!latest.isAcceptable(
            capturedContentRevision: 1,
            currentContentRevision: 2,
            previous: old,
            effectiveWidth: 320
        ))
    }

    @Test @MainActor func delayed_old_render_completion_cannot_measure_the_latest_commit() async throws {
        let scheduler = ManualPreparedRenderScheduler()
        let session = AgentMarkdownRenderSession(renderScheduler: scheduler.schedule)
        session.receive(
            .init(
                source: "old",
                generation: 1,
                contentVersion: 1,
                document: StreamingMarkdownDocument(source: "old")
            ),
            typography: typography,
            tone: .primary
        )
        session.receive(
            .init(
                source: "latest",
                generation: 2,
                contentVersion: 2,
                document: StreamingMarkdownDocument(source: "latest")
            ),
            typography: typography,
            tone: .primary
        )
        await scheduler.release(1)
        await scheduler.tasks[1].value
        let latestRender = try #require(session.latestCommit)
        let latest = AgentMarkdownRenderHeightCommit.measure(
            renderCommit: latestRender,
            key: renderKey(width: 320, contentVersion: 2),
            verticalInset: 4
        )
        await scheduler.release(0)
        await scheduler.tasks[0].value

        #expect(latest.renderCommit.source == "latest")
        #expect(session.latestCommit === latest.renderCommit)
    }

    @Test @MainActor func same_snapshot_style_refresh_rejects_an_older_render_job() async throws {
        let scheduler = ManualPreparedRenderScheduler()
        let recorder = PreparedCommitRecorder()
        let session = AgentMarkdownRenderSession(
            renderScheduler: scheduler.schedule,
            onCommit: recorder.record
        )
        let snapshot = StreamingMarkdownSession.PreparedSnapshot(
            source: "Same **source**",
            generation: 7,
            contentVersion: 3,
            document: StreamingMarkdownDocument(source: "Same **source**")
        )

        session.receive(
            snapshot,
            typography: typography,
            tone: .primary,
            resourceIdentity: "project",
            styleRevision: 1,
            resourceGeneration: 1
        )
        session.receive(
            snapshot,
            typography: typography,
            tone: .primary,
            resourceIdentity: "project",
            styleRevision: 2,
            resourceGeneration: 2,
            forceStyleRefresh: true
        )
        await scheduler.release(1)
        await scheduler.tasks[1].value
        let latest = try #require(session.latestCommit)
        let measured = AgentMarkdownRenderHeightCommit.measure(
            renderCommit: latest,
            key: renderKey(
                contentVersion: 3,
                styleRevision: 2,
                resourceGeneration: 2
            ),
            verticalInset: 4
        )
        await scheduler.release(0)
        await scheduler.tasks[0].value

        #expect(recorder.commits.count == 1)
        #expect(session.preparationCount == 1)
        #expect(session.latestCommit === latest)
        #expect(latest.styleRevision == 2)
        #expect(latest.resourceGeneration == 2)
        #expect(measured.renderCommit === latest)
    }

    @Test @MainActor func detached_textkit_height_contains_the_same_commit_glyph_used_rect() {
        let rendered = commit(
            document: StreamingMarkdownDocument(
                source: String(repeating: "A wrapping **Markdown** line. ", count: 20)
            ),
            generation: 1,
            contentVersion: 1
        )
        let measured = AgentMarkdownRenderHeightCommit.measure(
            renderCommit: rendered,
            key: renderKey(width: 280),
            verticalInset: 4
        )

        #expect(measured.usedRect.maxY + 8 <= measured.height + 1)
        #expect(measured.usedRect.height > typography.pointSize)
    }

    @Test @MainActor func unprepared_hidden_measurement_does_not_parse_or_render_markdown() {
        let counter = MarkdownDocumentBuildCounter()
        let store = AgentMarkdownRenderStore(documentBuilder: counter.build)

        #expect(store.heightCommit(rowID: "cold", width: 320, verticalInset: 4) == nil)
        #expect(counter.count == 0)
    }

    @Test @MainActor func phase_only_update_to_final_reuses_render_and_height_version() async throws {
        let store = AgentMarkdownRenderStore()
        let firstResult = store.submit(
            rowID: "output",
            source: "Same **terminal** source",
            typography: typography,
            tone: .primary
        )
        try await waitUntil { store.latestRenderCommit(rowID: "output") != nil }
        let first = try #require(store.heightCommit(rowID: "output", width: 420, verticalInset: 4))
        let secondResult = store.submit(
            rowID: "output",
            source: "Same **terminal** source",
            typography: typography,
            tone: .primary
        )

        #expect(firstResult == .accepted(contentVersion: 1))
        #expect(secondResult == .unchanged(contentVersion: 1))
        #expect(store.heightCommit(rowID: "output", width: 420, verticalInset: 4) === first)
    }

    @Test @MainActor func offscreen_reconfigure_reappear_retains_the_semantic_session_and_commit() async throws {
        let counter = MarkdownDocumentBuildCounter()
        let store = AgentMarkdownRenderStore(documentBuilder: counter.build)
        let identity = markdownIdentity(rowID: "response-42", segment: .agentResponse)

        _ = store.submit(
            identity: identity,
            source: "Stable **prepared** response",
            typography: typography,
            tone: .primary
        )
        try await waitUntil { store.latestRenderCommit(identity: identity) != nil }
        let session = try #require(store.testingSession(identity: identity))
        let commit = try #require(store.latestRenderCommit(identity: identity))
        let preparationCount = session.preparationCount

        let visibleHost = NativeSelectableAgentMarkdownView.Coordinator()
        let visibleTextView = NativeAgentMarkdownTextView(frame: .zero)
        visibleHost.receivePreparedCommit(commit, isAuthoritative: true, to: visibleTextView)

        let reappearedHost = NativeSelectableAgentMarkdownView.Coordinator()
        let reappearedTextView = NativeAgentMarkdownTextView(frame: .zero)
        reappearedHost.receivePreparedCommit(commit, isAuthoritative: true, to: reappearedTextView)
        let repeated = store.submit(
            identity: identity,
            source: "Stable **prepared** response",
            typography: typography,
            tone: .primary
        )

        #expect(repeated == .unchanged(contentVersion: 1))
        #expect(store.testingSession(identity: identity) === session)
        #expect(store.latestRenderCommit(identity: identity) === commit)
        #expect(counter.count == 1)
        #expect(session.preparationCount == preparationCount)
        #expect(visibleTextView.string == reappearedTextView.string)
    }

    @Test @MainActor func identical_input_is_inert_across_render_apply_measure_and_height_publication() async throws {
        let counter = MarkdownDocumentBuildCounter()
        let store = AgentMarkdownRenderStore(documentBuilder: counter.build)
        let identity = markdownIdentity(rowID: "terminal", segment: .runOutput)
        let coordinator = NativeSelectableAgentMarkdownView.Coordinator()
        let textView = NativeAgentMarkdownTextView(frame: .zero)

        _ = store.submit(
            identity: identity,
            source: "Same **terminal** source",
            typography: typography,
            tone: .primary
        )
        try await waitUntil { store.latestRenderCommit(identity: identity) != nil }
        let session = try #require(store.testingSession(identity: identity))
        let commit = try #require(store.latestRenderCommit(identity: identity))
        coordinator.receivePreparedCommit(commit, isAuthoritative: true, to: textView)
        let measured = try #require(store.heightCommit(
            identity: identity,
            width: 420,
            verticalInset: 4
        ))
        #expect(coordinator.shouldPublishHeight(measured, identity: identity))

        let parseCount = counter.count
        let preparationCount = session.preparationCount
        let applyCount = coordinator.preparedApplyCount
        let measurementCount = store.testingMeasurementCount
        let repeated = store.submit(
            identity: identity,
            source: "Same **terminal** source",
            typography: typography,
            tone: .primary
        )
        coordinator.receivePreparedCommit(commit, isAuthoritative: true, to: textView)

        #expect(repeated == .unchanged(contentVersion: 1))
        #expect(store.heightCommit(identity: identity, width: 420, verticalInset: 4) === measured)
        #expect(!coordinator.shouldPublishHeight(measured, identity: identity))
        #expect(counter.count == parseCount)
        #expect(session.preparationCount == preparationCount)
        #expect(coordinator.preparedApplyCount == applyCount)
        #expect(store.testingMeasurementCount == measurementCount)
        #expect(coordinator.shouldPublishHeight(
            measured,
            identity: markdownIdentity(rowID: "other", segment: .runOutput)
        ))
    }

    @Test @MainActor func width_only_change_measures_the_existing_commit_without_parse_or_render() async throws {
        let counter = MarkdownDocumentBuildCounter()
        let store = AgentMarkdownRenderStore(documentBuilder: counter.build)
        let identity = markdownIdentity(rowID: "wrapping", segment: .agentResponse)

        _ = store.submit(
            identity: identity,
            source: String(repeating: "A wrapping **Markdown** response. ", count: 20),
            typography: typography,
            tone: .primary
        )
        try await waitUntil { store.latestRenderCommit(identity: identity) != nil }
        let session = try #require(store.testingSession(identity: identity))
        let commit = try #require(store.latestRenderCommit(identity: identity))
        let narrow = try #require(store.heightCommit(identity: identity, width: 320, verticalInset: 4))
        let parseCount = counter.count
        let preparationCount = session.preparationCount

        let wide = try #require(store.heightCommit(identity: identity, width: 720, verticalInset: 4))

        #expect(narrow !== wide)
        #expect(narrow.renderCommit === commit)
        #expect(wide.renderCommit === commit)
        #expect(wide.height < narrow.height)
        #expect(counter.count == parseCount)
        #expect(session.preparationCount == preparationCount)
    }

    @Test @MainActor func semantic_identity_does_not_alias_projects_sessions_rows_or_segments() async throws {
        let store = AgentMarkdownRenderStore()
        let base = markdownIdentity(rowID: "shared-id", segment: .agentResponse)
        let sibling = markdownIdentity(rowID: "shared-id", segment: .thinking)
        let otherSession = AgentMarkdownRenderIdentity(
            scope: .init(projectIdentity: "project-a", sessionID: "session-b"),
            rowID: "shared-id",
            segment: .agentResponse
        )
        let otherProject = AgentMarkdownRenderIdentity(
            scope: .init(projectIdentity: "project-b", sessionID: "session-a"),
            rowID: "shared-id",
            segment: .agentResponse
        )

        #expect(Set([base, sibling, otherSession, otherProject]).count == 4)

        _ = store.submit(
            identity: base,
            source: "Agent response",
            typography: typography,
            tone: .primary
        )
        _ = store.submit(
            identity: sibling,
            source: "Thinking response",
            typography: typography,
            tone: .secondary
        )
        try await waitUntil {
            store.latestRenderCommit(identity: base) != nil
                && store.latestRenderCommit(identity: sibling) != nil
        }

        #expect(store.testingSession(identity: base) !== store.testingSession(identity: sibling))

        _ = store.submit(
            identity: otherSession,
            source: "Other session",
            typography: typography,
            tone: .primary
        )
        #expect(store.testingIdentities == Set([otherSession]))

        _ = store.submit(
            identity: otherProject,
            source: "Other project",
            typography: typography,
            tone: .primary
        )
        #expect(store.testingIdentities == Set([otherProject]))
    }

    @Test @MainActor func inserted_prefix_and_repeated_siblings_do_not_reuse_positional_blocks() {
        let originalDocument = StreamingMarkdownDocument(source: "Same paragraph.\n\nSame paragraph.")
        let original = commit(
            document: originalDocument,
            generation: 1,
            contentVersion: 1
        )
        let insertedDocument = StreamingMarkdownDocument(
            source: "Inserted paragraph.\n\nSame paragraph.\n\nSame paragraph.",
            previous: originalDocument
        )
        let inserted = commit(
            document: insertedDocument,
            generation: 2,
            contentVersion: 2,
            previous: original
        )

        #expect(insertedDocument.stablePrefixCount == 0)
        #expect(inserted.isFullReplacement)
        #expect(inserted.blocks[1].attributedValue !== original.blocks[0].attributedValue)
        #expect(inserted.blocks[2].attributedValue !== original.blocks[1].attributedValue)
        #expect(inserted.document.preparedBlocks[1].sourceRange
            != original.document.preparedBlocks[0].sourceRange)
    }

    @Test @MainActor func repeated_same_kind_children_survive_prefix_insertion_and_reordering() async throws {
        let counter = MarkdownDocumentBuildCounter()
        let store = AgentMarkdownRenderStore(documentBuilder: counter.build)
        let parentRowID = "run-1-activity-details"
        let first = markdownIdentity(
            rowID: parentRowID,
            semanticItemID: "thinking-a",
            segment: .thinking
        )
        let second = markdownIdentity(
            rowID: parentRowID,
            semanticItemID: "thinking-b",
            segment: .thinking
        )

        _ = store.submit(identity: first, source: "First thought", typography: typography, tone: .secondary)
        _ = store.submit(identity: second, source: "Second thought", typography: typography, tone: .secondary)
        try await waitUntil {
            store.latestRenderCommit(identity: first) != nil
                && store.latestRenderCommit(identity: second) != nil
        }
        let firstSession = try #require(store.testingSession(identity: first))
        let secondSession = try #require(store.testingSession(identity: second))
        let firstCommit = try #require(store.latestRenderCommit(identity: first))
        let secondCommit = try #require(store.latestRenderCommit(identity: second))

        #expect(firstSession !== secondSession)
        #expect(firstCommit !== secondCommit)

        let prefix = markdownIdentity(
            rowID: parentRowID,
            semanticItemID: "thinking-prefix",
            segment: .thinking
        )
        _ = store.submit(identity: prefix, source: "Prefixed thought", typography: typography, tone: .secondary)
        try await waitUntil { store.latestRenderCommit(identity: prefix) != nil }

        // Re-reading in presentation order models prefix insertion followed by sibling reorder.
        for identity in [second, prefix, first] {
            _ = store.latestRenderCommit(identity: identity)
        }
        store.reconcile(scope: first.scope, retainingRowIDs: [parentRowID])

        #expect(store.testingSession(identity: first) === firstSession)
        #expect(store.testingSession(identity: second) === secondSession)
        #expect(store.latestRenderCommit(identity: first) === firstCommit)
        #expect(store.latestRenderCommit(identity: second) === secondCommit)
        #expect(store.testingIdentities == Set([first, second, prefix]))
        #expect(counter.count == 3)

        store.reconcile(scope: first.scope, retainingRowIDs: [])
        #expect(store.testingIdentities.isEmpty)
    }

    @Test @MainActor func row_store_capacity_and_lru_eviction_are_deterministic() {
        let store = AgentMarkdownRenderStore(capacity: 2)
        let first = markdownIdentity(rowID: "first", segment: .agentResponse)
        let second = markdownIdentity(rowID: "second", segment: .agentResponse)
        let third = markdownIdentity(rowID: "third", segment: .agentResponse)

        _ = store.submit(identity: first, source: "First", typography: typography, tone: .primary)
        _ = store.submit(identity: second, source: "Second", typography: typography, tone: .primary)
        _ = store.latestRenderCommit(identity: first)
        _ = store.submit(identity: third, source: "Third", typography: typography, tone: .primary)

        #expect(store.testingIdentities == Set([first, third]))
        #expect(store.testingSession(identity: second) == nil)
    }

    @Test @MainActor func width_cache_capacity_and_lru_eviction_are_deterministic() async throws {
        let store = AgentMarkdownRenderStore(heightCapacityPerRow: 2)
        let identity = markdownIdentity(rowID: "bounded-widths", segment: .agentResponse)

        _ = store.submit(
            identity: identity,
            source: String(repeating: "Width-sensitive Markdown. ", count: 12),
            typography: typography,
            tone: .primary
        )
        try await waitUntil { store.latestRenderCommit(identity: identity) != nil }
        let first = try #require(store.heightCommit(identity: identity, width: 320, verticalInset: 4))
        let second = try #require(store.heightCommit(identity: identity, width: 480, verticalInset: 4))
        #expect(store.heightCommit(identity: identity, width: 320, verticalInset: 4) === first)
        let third = try #require(store.heightCommit(identity: identity, width: 720, verticalInset: 4))

        #expect(store.testingHeightKeys(identity: identity) == [first.key, third.key])
        #expect(store.heightCommit(identity: identity, width: 480, verticalInset: 4) !== second)
        #expect(store.testingMeasurementCount == 4)
    }

    @Test @MainActor func row_and_scope_teardown_cancel_stale_completion_and_release_sessions() async {
        let scheduler = ManualPreparedDocumentScheduler()
        let store = AgentMarkdownRenderStore(documentScheduler: scheduler.schedule)
        let first = markdownIdentity(rowID: "first", segment: .agentResponse)
        let second = markdownIdentity(rowID: "second", segment: .agentResponse)

        _ = store.submit(identity: first, source: "First", typography: typography, tone: .primary)
        _ = store.submit(identity: second, source: "Second", typography: typography, tone: .primary)
        let releasedSession = WeakMarkdownRenderSession(
            store.testingSession(identity: first)
        )

        store.reconcile(scope: first.scope, retainingRowIDs: ["second"])
        await scheduler.release(0)
        await scheduler.tasks[0].value

        #expect(releasedSession.value == nil)
        #expect(store.latestRenderCommit(identity: first) == nil)
        #expect(store.testingIdentities == Set([second]))

        let replacementScope = AgentMarkdownRenderScope(
            projectIdentity: "project-b",
            sessionID: "session-b"
        )
        store.reconcile(scope: replacementScope, retainingRowIDs: [])

        #expect(store.testingIdentities.isEmpty)
    }

    @Test @MainActor func resolved_attachment_publishes_exactly_one_newer_render_height_commit() async throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 20,
            pixelsHigh: 10,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let imageData = try #require(bitmap.representation(using: .png, properties: [:]))
        let resolver = MarkdownAttachmentResolver(data: imageData)
        let store = AgentMarkdownRenderStore(attachmentResolver: { _, _ in
            await resolver.resolve()
        })
        _ = store.submit(
            rowID: "image",
            source: "![pixel](asset.png)",
            typography: typography,
            tone: .primary
        )
        try await waitUntil {
            store.latestRenderInputs(rowID: "image")?.attachmentResolutionGeneration == 1
        }
        let settled = try #require(store.latestRenderInputs(rowID: "image"))
        #expect(settled.attachmentResolutionGeneration == 1)
        #expect(settled.renderPublicationVersion == 2)
        let measured = try #require(store.heightCommit(
            rowID: "image",
            width: 420,
            verticalInset: 4
        ))

        let item = TranscriptGeometryItem(
            id: "image",
            contentRevision: 1,
            layoutRevision: 0,
            heightAuthority: .versionedRender
        )
        let initialSize = TranscriptGeometryItemSize(
            itemID: "image",
            contentRevision: 1,
            layoutRevision: 0,
            contentVersion: settled.contentVersion,
            renderPublicationVersion: 1,
            effectiveWidth: 420,
            height: 20
        )
        let settledSize = TranscriptGeometryItemSize(
            itemID: "image",
            contentRevision: 1,
            layoutRevision: 0,
            contentVersion: settled.contentVersion,
            renderPublicationVersion: settled.renderPublicationVersion,
            effectiveWidth: 420,
            height: measured.height
        )
        let viewport = TranscriptGeometryViewportIntent(revision: 1, mode: .followTail)
        var geometry = TranscriptGeometryTransactionState(committed: .init(
            items: [item],
            sizes: ["image": initialSize],
            bottomInset: 80,
            effectiveWidth: 420,
            viewportIntent: viewport
        ))
        let settledTarget = TranscriptGeometryTarget(
            items: [item],
            sizes: ["image": settledSize],
            bottomInset: 80,
            effectiveWidth: 420,
            viewportIntent: viewport
        )
        let settlementIntent = geometry.submit(settledTarget)
        #expect(settlementIntent == 1)
        let geometryTransaction = geometry.beginIfReady()
        #expect(geometryTransaction?.generation == 1)

        let unchanged = store.submit(
            rowID: "image",
            source: "![pixel](asset.png)",
            typography: typography,
            tone: .primary
        )
        await Task.yield()
        let callCount = await resolver.callCount
        #expect(unchanged == .unchanged(contentVersion: 1))
        #expect(callCount == 1)
        #expect(store.latestRenderInputs(rowID: "image") == settled)
        let duplicateGeometry = geometry.submit(settledTarget)
        #expect(duplicateGeometry == nil)
        #expect(geometry.nextTransactionGeneration == 2)
    }

    @Test @MainActor func superseded_attachment_completion_cannot_publish_during_newer_render_request() async throws {
        let documentScheduler = ManualPreparedDocumentScheduler()
        let resolver = GatedMarkdownAttachmentResolver(data: try imageData())
        let store = AgentMarkdownRenderStore(
            documentScheduler: documentScheduler.schedule,
            attachmentResolver: { _, _ in await resolver.resolve() }
        )

        #expect(store.submit(
            rowID: "image",
            source: "![old](asset.png)\n\nold tail",
            typography: typography,
            tone: .primary
        ) == .accepted(contentVersion: 1))
        await documentScheduler.release(0)
        await documentScheduler.tasks[0].value
        try await waitUntil { store.latestRenderCommit(rowID: "image") != nil }
        try await resolver.waitForCallCount(1)
        let unresolved = try #require(store.latestRenderInputs(rowID: "image"))
        #expect(unresolved.renderPublicationVersion == 1)
        #expect(unresolved.attachmentResolutionGeneration == 0)

        #expect(store.submit(
            rowID: "image",
            source: "![new](asset.png)\n\nnew tail",
            typography: typography,
            tone: .primary
        ) == .accepted(contentVersion: 2))
        await resolver.release(0)
        await resolver.waitForCompletion(0)
        for _ in 0..<8 { await Task.yield() }

        #expect(store.latestRenderInputs(rowID: "image") == unresolved)

        await documentScheduler.release(1)
        await documentScheduler.tasks[1].value
        try await resolver.waitForCallCount(2)
        await resolver.release(1)
        await resolver.waitForCompletion(1)
        try await waitUntil {
            store.latestRenderInputs(rowID: "image")?.attachmentResolutionGeneration == 1
        }
        let settled = try #require(store.latestRenderInputs(rowID: "image"))
        #expect(settled.contentVersion == 2)
        #expect(settled.renderPublicationVersion == 3)
        #expect(settled.attachmentResolutionGeneration == 1)
        #expect(await resolver.callCount == 2)
    }

    @Test @MainActor func phase_only_duplicate_keeps_one_attachment_resolution() async throws {
        let documentScheduler = ManualPreparedDocumentScheduler()
        let resolver = GatedMarkdownAttachmentResolver(data: try imageData())
        let store = AgentMarkdownRenderStore(
            documentScheduler: documentScheduler.schedule,
            attachmentResolver: { _, _ in await resolver.resolve() }
        )
        let source = "![pixel](asset.png)"

        #expect(store.submit(
            rowID: "image",
            source: source,
            typography: typography,
            tone: .primary
        ) == .accepted(contentVersion: 1))
        await documentScheduler.release(0)
        await documentScheduler.tasks[0].value
        try await resolver.waitForCallCount(1)
        #expect(store.submit(
            rowID: "image",
            source: source,
            typography: typography,
            tone: .primary
        ) == .unchanged(contentVersion: 1))
        #expect(await resolver.callCount == 1)

        await resolver.release(0)
        await resolver.waitForCompletion(0)
        try await waitUntil {
            store.latestRenderInputs(rowID: "image")?.attachmentResolutionGeneration == 1
        }
        let settled = try #require(store.latestRenderInputs(rowID: "image"))
        #expect(settled.renderPublicationVersion == 2)
        #expect(settled.attachmentResolutionGeneration == 1)
        #expect(await resolver.callCount == 1)
    }

    @Test @MainActor func project_resource_invalidation_refreshes_only_matching_image_rows() async throws {
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:1")!,
            token: "test"
        )
        let context = MarkdownProjectResourceContext(
            identity: "server:project",
            projectID: "project",
            client: client
        )
        let store = AgentMarkdownRenderStore(attachmentResolver: { _, _ in nil })
        _ = store.submit(
            rowID: "diagram",
            source: "![diagram](docs/diagram.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        _ = store.submit(
            rowID: "other",
            source: "![other](docs/other.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        _ = store.submit(
            rowID: "remote",
            source: "![remote](https://example.com/image.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        _ = store.submit(
            rowID: "text",
            source: "No image dependency",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        try await waitUntil {
            store.latestRenderInputs(rowID: "diagram") != nil
                && store.latestRenderInputs(rowID: "other") != nil
                && store.latestRenderInputs(rowID: "remote") != nil
                && store.latestRenderInputs(rowID: "text") != nil
        }
        let otherInputs = try #require(store.latestRenderInputs(rowID: "other"))
        let remoteInputs = try #require(store.latestRenderInputs(rowID: "remote"))
        let textInputs = try #require(store.latestRenderInputs(rowID: "text"))

        #expect(store.invalidateResourceContext(
            identity: context.identity,
            projectPath: "docs/diagram.png"
        ) == 1)
        try await waitUntil {
            store.latestRenderInputs(rowID: "diagram")?.resourceGeneration == 2
        }

        #expect(store.latestRenderInputs(rowID: "other") == otherInputs)
        #expect(store.latestRenderInputs(rowID: "remote") == remoteInputs)
        #expect(store.latestRenderInputs(rowID: "text") == textInputs)
        #expect(store.invalidateResourceContext(
            identity: context.identity,
            projectPath: "../secret.png"
        ) == 0)
    }

    @Test @MainActor func path_invalidation_does_not_refresh_an_unrelated_row_on_its_next_submit() async throws {
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:1")!,
            token: "test"
        )
        let context = MarkdownProjectResourceContext(
            identity: "server:project",
            projectID: "project",
            client: client
        )
        let resolver = MarkdownAttachmentResolver(data: try imageData())
        let store = AgentMarkdownRenderStore(attachmentResolver: { _, _ in
            await resolver.resolve()
        })
        _ = store.submit(
            rowID: "diagram",
            source: "![diagram](docs/diagram.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        _ = store.submit(
            rowID: "other",
            source: "![other](docs/other.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        try await waitUntil {
            store.latestRenderInputs(rowID: "diagram")?.attachmentResolutionGeneration == 1
                && store.latestRenderInputs(rowID: "other")?.attachmentResolutionGeneration == 1
        }
        let otherInputs = try #require(store.latestRenderInputs(rowID: "other"))
        let resolverCallsBeforeInvalidation = await resolver.callCount

        #expect(store.invalidateResourceContext(
            identity: context.identity,
            projectPath: "docs/diagram.png"
        ) == 1)
        try await waitUntil {
            store.latestRenderInputs(rowID: "diagram")?.resourceGeneration == 2
        }
        await resolver.waitForCallCount(resolverCallsBeforeInvalidation + 1)
        let resolverCallsAfterInvalidation = await resolver.callCount
        #expect(resolverCallsAfterInvalidation == resolverCallsBeforeInvalidation + 1)

        let result = store.submit(
            rowID: "other",
            source: "![other](docs/other.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        for _ in 0..<8 { await Task.yield() }

        #expect(result == .unchanged(contentVersion: otherInputs.contentVersion))
        #expect(store.latestRenderInputs(rowID: "other") == otherInputs)
        #expect(await resolver.callCount == resolverCallsAfterInvalidation)
    }

    @Test @MainActor func local_path_invalidation_skips_unprepared_text_and_remote_rows() async throws {
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:1")!,
            token: "test"
        )
        let context = MarkdownProjectResourceContext(
            identity: "server:project",
            projectID: "project",
            client: client
        )
        let documentScheduler = ManualPreparedDocumentScheduler()
        let store = AgentMarkdownRenderStore(documentScheduler: documentScheduler.schedule)
        _ = store.submit(
            rowID: "pending-text",
            source: "No local image dependency",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        _ = store.submit(
            rowID: "pending-remote",
            source: "![remote](https://example.com/image.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )

        #expect(store.invalidateResourceContext(
            identity: context.identity,
            projectPath: "docs/diagram.png"
        ) == 0)
        #expect(store.latestRenderCommit(rowID: "pending-text") == nil)
        #expect(store.latestRenderCommit(rowID: "pending-remote") == nil)
        #expect(documentScheduler.tasks.count == 2)

        await documentScheduler.release(0)
        await documentScheduler.release(1)
        for task in documentScheduler.tasks { await task.value }
    }

    @Test @MainActor func project_invalidation_cancels_the_old_attachment_epoch_before_resubmit() async throws {
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:1")!,
            token: "test"
        )
        let context = MarkdownProjectResourceContext(
            identity: "server:project",
            projectID: "project",
            client: client
        )
        let documentScheduler = ManualPreparedDocumentScheduler()
        let resolver = GatedMarkdownAttachmentResolver(data: try imageData())
        let store = AgentMarkdownRenderStore(
            documentScheduler: documentScheduler.schedule,
            attachmentResolver: { _, _ in await resolver.resolve() }
        )
        _ = store.submit(
            rowID: "diagram",
            source: "![diagram](docs/diagram.png)",
            typography: typography,
            tone: .primary,
            resourceContext: context
        )
        await documentScheduler.release(0)
        await documentScheduler.tasks[0].value
        try await resolver.waitForCallCount(1)
        let unresolved = try #require(store.latestRenderInputs(rowID: "diagram"))

        #expect(store.invalidateResourceContext(
            identity: context.identity,
            projectPath: "docs/diagram.png"
        ) == 1)
        try await waitUntil {
            store.latestRenderInputs(rowID: "diagram")?.resourceGeneration == 2
        }
        try await resolver.waitForCallCount(2)
        let refreshed = try #require(store.latestRenderInputs(rowID: "diagram"))
        #expect(refreshed.renderPublicationVersion == unresolved.renderPublicationVersion + 1)
        #expect(refreshed.attachmentResolutionGeneration == 0)

        await resolver.release(0)
        await resolver.waitForCompletion(0)
        for _ in 0..<8 { await Task.yield() }
        #expect(store.latestRenderInputs(rowID: "diagram") == refreshed)

        await resolver.release(1)
        await resolver.waitForCompletion(1)
        try await waitUntil {
            store.latestRenderInputs(rowID: "diagram")?.attachmentResolutionGeneration == 1
        }
        let settled = try #require(store.latestRenderInputs(rowID: "diagram"))
        #expect(settled.resourceGeneration == 2)
        #expect(settled.renderPublicationVersion == refreshed.renderPublicationVersion + 1)
    }

    @Test @MainActor func visible_and_hidden_hosts_share_the_prepared_row_commit() async throws {
        let store = AgentMarkdownRenderStore()
        _ = store.submit(
            rowID: "shared-row",
            source: "One **prepared** value",
            typography: typography,
            tone: .primary
        )
        try await waitUntil { store.latestRenderCommit(rowID: "shared-row") != nil }

        let visible = store.latestRenderCommit(rowID: "shared-row")
        let hidden = store.latestRenderCommit(rowID: "shared-row")
        #expect(visible === hidden)
        #expect(store.heightCommit(rowID: "shared-row", width: 360, verticalInset: 4)?.renderCommit
            === visible)
    }

    @Test @MainActor func style_resource_refresh_drops_old_prefix_attachment_but_compatible_append_reuses_it() throws {
        let firstDocument = StreamingMarkdownDocument(
            source: "![pixel](asset.png)\n\nmutable tail"
        )
        let appendedDocument = StreamingMarkdownDocument(
            source: "![pixel](asset.png)\n\nmutable tail appended",
            previous: firstDocument
        )
        let oldImage = NSImage(size: NSSize(width: 24, height: 12))
        let newImage = NSImage(size: NSSize(width: 32, height: 16))
        let first = commit(
            document: firstDocument,
            generation: 1,
            contentVersion: 1,
            images: ["asset.png": oldImage],
            styleRevision: 1,
            resourceIdentity: "project",
            resourceGeneration: 1
        )
        let compatibleAppend = commit(
            document: appendedDocument,
            generation: 2,
            contentVersion: 2,
            previous: first,
            styleRevision: 1,
            resourceIdentity: "project",
            resourceGeneration: 1
        )
        let invalidatedAppend = commit(
            document: appendedDocument,
            generation: 2,
            contentVersion: 2,
            previous: first,
            images: ["asset.png": newImage],
            styleRevision: 2,
            resourceIdentity: "project",
            resourceGeneration: 2
        )
        let sameSourceRefresh = commit(
            document: firstDocument,
            generation: 1,
            contentVersion: 1,
            previous: first,
            images: ["asset.png": newImage],
            styleRevision: 2,
            resourceIdentity: "project",
            resourceGeneration: 2
        )
        let refreshedAttachment = try #require(sameSourceRefresh.attributedValue.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? NSTextAttachment)

        #expect(compatibleAppend.blocks[0].attributedValue === first.blocks[0].attributedValue)
        #expect(!compatibleAppend.isFullReplacement)
        #expect(invalidatedAppend.blocks[0].attributedValue !== first.blocks[0].attributedValue)
        #expect(invalidatedAppend.isFullReplacement)
        #expect(sameSourceRefresh.blocks[0].attributedValue !== first.blocks[0].attributedValue)
        #expect(refreshedAttachment.image === newImage)
    }

    @Test @MainActor func prepared_suffix_apply_preserves_completed_prefix_ranges() throws {
        let firstDocument = StreamingMarkdownDocument(source: "# Complete\n\nTail")
        let secondDocument = StreamingMarkdownDocument(
            source: "# Complete\n\nTail grows",
            previous: firstDocument
        )
        let first = commit(document: firstDocument, generation: 1, contentVersion: 1)
        let second = commit(
            document: secondDocument,
            generation: 2,
            contentVersion: 2,
            previous: first
        )

        #expect(secondDocument.stablePrefixCount == 1)
        #expect(second.blocks[0].id == first.blocks[0].id)
        #expect(second.blocks[0].sourceRange == first.blocks[0].sourceRange)
        #expect(second.blocks[0].attributedValue === first.blocks[0].attributedValue)
        #expect(second.replacementRange.location == NSMaxRange(first.blocks[0].attributedRange))

        let textView = NativeAgentMarkdownTextView(frame: .zero)
        textView.textStorage?.setAttributedString(first.attributedValue)
        let result = NativeMarkdownSuffixApplier.apply(second, to: textView)

        #expect(result == .replacedSuffix(second.replacementRange))
        #expect(textView.string == second.attributedValue.string)
    }

    @Test @MainActor func suffix_apply_preserves_selection_inside_stable_prefix() {
        let firstDocument = StreamingMarkdownDocument(source: "Stable prefix\n\nmutable tail")
        let secondDocument = StreamingMarkdownDocument(
            source: "Stable prefix\n\nmutable tail appended",
            previous: firstDocument
        )
        let first = commit(document: firstDocument, generation: 1, contentVersion: 1)
        let second = commit(
            document: secondDocument,
            generation: 2,
            contentVersion: 2,
            previous: first
        )
        let textView = NativeAgentMarkdownTextView(frame: .zero)
        textView.textStorage?.setAttributedString(first.attributedValue)
        let selection = NSRange(location: 2, length: 6)
        textView.setSelectedRange(selection)

        _ = NativeMarkdownSuffixApplier.apply(second, to: textView)

        #expect(textView.selectedRange() == selection)
    }

    @Test @MainActor func suffix_apply_clamps_selection_intersecting_replaced_tail() {
        let firstDocument = StreamingMarkdownDocument(source: "Stable prefix\n\nmutable tail")
        let secondDocument = StreamingMarkdownDocument(
            source: "Stable prefix\n\nmutable tail appended",
            previous: firstDocument
        )
        let first = commit(document: firstDocument, generation: 1, contentVersion: 1)
        let second = commit(
            document: secondDocument,
            generation: 2,
            contentVersion: 2,
            previous: first
        )
        let textView = NativeAgentMarkdownTextView(frame: .zero)
        textView.textStorage?.setAttributedString(first.attributedValue)
        textView.setSelectedRange(NSRange(
            location: max(0, second.replacementRange.location - 2),
            length: 5
        ))

        _ = NativeMarkdownSuffixApplier.apply(second, to: textView)

        #expect(textView.selectedRange() == NSRange(
            location: second.replacementRange.location,
            length: 0
        ))
    }

    @Test @MainActor func unsafe_reconciliation_falls_back_to_one_full_replace() {
        let firstDocument = StreamingMarkdownDocument(source: "# Original prefix\n\nTail")
        let uncommittedIntermediate = StreamingMarkdownDocument(
            source: "# Changed prefix\n\nTail",
            previous: firstDocument
        )
        let secondDocument = StreamingMarkdownDocument(
            source: "# Changed prefix\n\nTail grows",
            previous: uncommittedIntermediate
        )
        let first = commit(document: firstDocument, generation: 1, contentVersion: 1)
        let second = commit(
            document: secondDocument,
            generation: 2,
            contentVersion: 2,
            previous: first
        )
        let textView = NativeAgentMarkdownTextView(frame: .zero)
        textView.textStorage?.setAttributedString(first.attributedValue)

        let result = NativeMarkdownSuffixApplier.apply(second, to: textView)

        #expect(second.isFullReplacement)
        #expect(result == .replacedAll)
        #expect(textView.string == "Changed prefix\nTail grows")
    }

    @Test @MainActor func visible_apply_and_measurement_receive_the_same_prepared_render_commit() {
        let document = StreamingMarkdownDocument(source: "Prepared **value**")
        let prepared = commit(document: document, generation: 1, contentVersion: 1)
        let coordinator = NativeSelectableAgentMarkdownView.Coordinator()
        let textView = NativeAgentMarkdownTextView(frame: .zero)

        coordinator.applyPreparedCommit(prepared, to: textView)
        let measured = coordinator.measurementCommit(forSource: prepared.source)

        #expect(coordinator.latestPreparedCommit === prepared)
        #expect(measured === prepared)
        #expect(textView.attributedString().isEqual(to: prepared.attributedValue))
    }

    @Test @MainActor func resolved_stable_prefix_is_carried_into_the_next_suffix_commit_and_measurement() throws {
        let firstDocument = StreamingMarkdownDocument(
            source: "![pixel](asset.png)\n\nmutable tail"
        )
        let secondDocument = StreamingMarkdownDocument(
            source: "![pixel](asset.png)\n\nmutable tail appended",
            previous: firstDocument
        )
        let unresolvedFirst = commit(
            document: firstDocument,
            generation: 1,
            contentVersion: 1
        )
        let image = NSImage(size: NSSize(width: 24, height: 12))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let settledFirst = commit(
            document: firstDocument,
            generation: 1,
            contentVersion: 1,
            previous: unresolvedFirst,
            images: ["asset.png": image]
        )
        let unresolvedSecond = commit(
            document: secondDocument,
            generation: 2,
            contentVersion: 2,
            previous: unresolvedFirst
        )
        let coordinator = NativeSelectableAgentMarkdownView.Coordinator()
        let textView = NativeAgentMarkdownTextView(frame: .zero)

        coordinator.applyPreparedCommit(settledFirst, to: textView)
        coordinator.receivePreparedCommit(unresolvedSecond, to: textView)

        let measured = try #require(coordinator.measurementCommit(forSource: secondDocument.source))
        #expect(textView.attributedString().isEqual(to: measured.attributedValue))
        let attachment = try #require(measured.attributedValue.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? NSTextAttachment)
        #expect(attachment.image === image)
    }

    @Test @MainActor func delayed_old_render_completion_cannot_replace_the_latest_render_commit() async {
        let scheduler = ManualPreparedRenderScheduler()
        let recorder = PreparedCommitRecorder()
        let session = AgentMarkdownRenderSession(
            renderScheduler: scheduler.schedule,
            onCommit: recorder.record
        )
        let old = StreamingMarkdownSession.PreparedSnapshot(
            source: "old",
            generation: 1,
            contentVersion: 1,
            document: StreamingMarkdownDocument(source: "old")
        )
        let latest = StreamingMarkdownSession.PreparedSnapshot(
            source: "latest **rich**",
            generation: 2,
            contentVersion: 2,
            document: StreamingMarkdownDocument(source: "latest **rich**")
        )

        session.receive(old, typography: typography, tone: .primary)
        session.receive(latest, typography: typography, tone: .primary)
        #expect(scheduler.tasks.count == 2)

        await scheduler.release(1)
        await scheduler.tasks[1].value
        await scheduler.release(0)
        await scheduler.tasks[0].value

        #expect(recorder.commits.map(\.source) == ["latest **rich**"])
        #expect(session.latestCommit?.source == "latest **rich**")
        #expect(session.latestCommit?.contentVersion == 2)
    }

    @Test @MainActor func active_markdown_semantics_render_from_prepared_snapshot() throws {
        let source = #"""
        # Heading

        - **bold item**

        [Swift](https://swift.org) and $x^2$

        | Name | Value |
        | --- | ---: |
        | answer | 42 |
        """#
        let prepared = commit(
            document: StreamingMarkdownDocument(source: source),
            generation: 1,
            contentVersion: 1
        )

        #expect(prepared.attributedValue.string.contains("Heading"))
        #expect(prepared.attributedValue.string.contains("bold item"))
        #expect(prepared.attributedValue.string.contains("42"))
        let swiftRange = try #require(prepared.attributedValue.string.range(of: "Swift"))
        #expect(prepared.attributedValue.attribute(
            .link,
            at: NSRange(swiftRange, in: prepared.attributedValue.string).location,
            effectiveRange: nil
        ) as? URL == URL(string: "https://swift.org"))
        #expect(prepared.attributedValue.containsAttachments(
            in: NSRange(location: 0, length: prepared.attributedValue.length)
        ))
    }

    @Test @MainActor func thinking_rows_use_the_prepared_rich_path() async throws {
        let controller = NSHostingController(rootView: AgentMarkdownView(
            source: "Thinking with **strong semantics**",
            tone: .secondary,
            isStreaming: true
        ).frame(width: 420, alignment: .topLeading))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let textView = try #require(firstTextView(in: controller.view))
        try await waitUntil { textView.string.contains("strong semantics") }

        let range = try #require(textView.string.range(of: "strong semantics"))
        let font = try #require(textView.attributedString().attribute(
            .font,
            at: NSRange(range, in: textView.string).location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @Test @MainActor func size_that_fits_never_synchronously_parses_markdown() async throws {
        let coordinator = NativeSelectableAgentMarkdownView.Coordinator()
        let textView = NativeAgentMarkdownTextView(frame: .zero)

        #expect(coordinator.measurementCommit(forSource: "not prepared") == nil)
        #expect(coordinator.preparedRenderCount == 0)

        let prepared = commit(
            document: StreamingMarkdownDocument(source: "Prepared measurement"),
            generation: 1,
            contentVersion: 1
        )
        coordinator.applyPreparedCommit(prepared, to: textView)
        let renderCount = coordinator.preparedRenderCount

        #expect(coordinator.measurementCommit(forSource: "Prepared measurement")
            === coordinator.latestPreparedCommit)
        #expect(coordinator.preparedRenderCount == renderCount)
    }

    @Test @MainActor func identical_update_to_final_keeps_renderer_session_and_content_version() async throws {
        let recorder = PreparedCommitRecorder()
        let session = AgentMarkdownRenderSession(onCommit: recorder.record)
        let identity = session.identity

        #expect(session.submit(
            source: "Same **complete** source",
            generation: 1,
            typography: typography,
            tone: .primary
        ) == .accepted(contentVersion: 1))
        try await waitUntil { session.latestCommit != nil }
        let first = try #require(session.latestCommit)
        let preparationCount = session.preparationCount

        #expect(session.submit(
            source: "Same **complete** source",
            generation: 2,
            typography: typography,
            tone: .primary
        ) == .unchanged(contentVersion: 1))

        #expect(session.identity == identity)
        #expect(session.latestCommit === first)
        #expect(session.latestContentVersion == 1)
        #expect(session.preparationCount == preparationCount)
        #expect(recorder.commits.count == 1)
    }

    @Test @MainActor func mutable_render_session_store_is_main_actor_isolated() {
        let session = AgentMarkdownRenderSession()

        session.assertMainActorIsolation()
        #expect(session.latestCommit == nil)
    }

    @MainActor
    private func commit(
        document: StreamingMarkdownDocument,
        generation: Int,
        contentVersion: Int,
        previous: AgentMarkdownRenderCommit? = nil,
        images: [String: NSImage] = [:],
        styleRevision: Int = 0,
        resourceIdentity: String? = nil,
        resourceGeneration: Int = 0
    ) -> AgentMarkdownRenderCommit {
        AgentMarkdownRenderCommit.prepare(
            snapshot: .init(
                source: document.source,
                generation: generation,
                contentVersion: contentVersion,
                document: document
            ),
            previous: previous,
            typography: typography,
            tone: .primary,
            images: images,
            styleRevision: styleRevision,
            resourceIdentity: resourceIdentity,
            resourceGeneration: resourceGeneration
        )
    }

    private func renderKey(
        width: CGFloat = 319.4,
        contentVersion: Int = 1,
        renderPublicationVersion: Int = 1,
        typography: AgentMarkdownTypographyKey = .init(fontName: "System", pointSize: 14),
        styleRevision: Int = 1,
        tone: AgentMarkdownTone = .primary,
        resourceIdentity: String? = "project-1",
        resourceGeneration: Int = 1,
        attachmentResolutionGeneration: Int = 1
    ) -> AgentMarkdownRenderKey {
        AgentMarkdownRenderKey(
            contentVersion: contentVersion,
            renderPublicationVersion: renderPublicationVersion,
            typography: typography,
            styleRevision: styleRevision,
            tone: tone,
            resourceIdentity: resourceIdentity,
            resourceGeneration: resourceGeneration,
            attachmentResolutionGeneration: attachmentResolutionGeneration,
            effectiveWidth: width
        )
    }

    private func markdownIdentity(
        rowID: String,
        semanticItemID: String? = nil,
        segment: AgentMarkdownRenderSegment
    ) -> AgentMarkdownRenderIdentity {
        AgentMarkdownRenderIdentity(
            scope: .init(projectIdentity: "project-a", sessionID: "session-a"),
            rowID: rowID,
            semanticItemID: semanticItemID,
            segment: segment
        )
    }

    private func imageData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 20,
            pixelsHigh: 10,
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
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for prepared Markdown work")
                return
            }
            await Task.yield()
        }
    }

    @MainActor
    private func firstTextView(in view: NSView) -> NativeAgentMarkdownTextView? {
        if let textView = view as? NativeAgentMarkdownTextView { return textView }
        for child in view.subviews {
            if let textView = firstTextView(in: child) { return textView }
        }
        return nil
    }
}

@MainActor
private final class MarkdownDocumentBuildCounter {
    private(set) var count = 0

    func build(source: String, previous: StreamingMarkdownDocument?) -> StreamingMarkdownDocument {
        count += 1
        return StreamingMarkdownDocument(source: source, previous: previous)
    }
}

@MainActor
private final class PreparedCommitRecorder {
    private(set) var commits: [AgentMarkdownRenderCommit] = []

    func record(_ commit: AgentMarkdownRenderCommit) {
        commits.append(commit)
    }
}

@MainActor
private final class WeakMarkdownRenderSession {
    weak var value: AgentMarkdownRenderSession?

    init(_ value: AgentMarkdownRenderSession?) {
        self.value = value
    }
}

private actor ManualPreparedRenderGate {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []

    func wait(for index: Int) async {
        if released.remove(index) != nil { return }
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
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

private actor MarkdownAttachmentResolver {
    private let data: Data
    private var callCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var callCount = 0

    init(data: Data) {
        self.data = data
    }

    func resolve() -> Data {
        callCount += 1
        for expected in callCountWaiters.keys.filter({ $0 <= callCount }) {
            for continuation in callCountWaiters.removeValue(forKey: expected) ?? [] {
                continuation.resume()
            }
        }
        return data
    }

    func waitForCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters[expected, default: []].append(continuation)
        }
    }
}

private actor GatedMarkdownAttachmentResolver {
    private let data: Data
    private let gate = ManualPreparedRenderGate()
    private var callCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completed: Set<Int> = []
    private(set) var callCount = 0

    init(data: Data) {
        self.data = data
    }

    func resolve() async -> Data {
        let index = callCount
        callCount += 1
        for expected in callCountWaiters.keys.filter({ $0 <= callCount }) {
            for continuation in callCountWaiters.removeValue(forKey: expected) ?? [] {
                continuation.resume()
            }
        }
        await gate.wait(for: index)
        completed.insert(index)
        for continuation in completionWaiters.removeValue(forKey: index) ?? [] {
            continuation.resume()
        }
        return data
    }

    func release(_ index: Int) async {
        await gate.release(index)
    }

    func waitForCallCount(_ expected: Int) async throws {
        if callCount >= expected { return }
        await withCheckedContinuation { continuation in
            callCountWaiters[expected, default: []].append(continuation)
        }
    }

    func waitForCompletion(_ index: Int) async {
        if completed.contains(index) { return }
        await withCheckedContinuation { continuation in
            completionWaiters[index, default: []].append(continuation)
        }
    }
}

@MainActor
private final class ManualPreparedDocumentScheduler {
    private let gate = ManualPreparedRenderGate()
    private(set) var tasks: [Task<Void, Never>] = []

    func schedule(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let index = tasks.count
        let gate = gate
        let task = Task {
            await gate.wait(for: index)
            await operation()
        }
        tasks.append(task)
        return task
    }

    func release(_ index: Int) async {
        await gate.release(index)
    }
}

@MainActor
private final class ManualPreparedRenderScheduler {
    private let gate = ManualPreparedRenderGate()
    private(set) var tasks: [Task<Void, Never>] = []

    func schedule(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let index = tasks.count
        let gate = gate
        let task = Task { @MainActor in
            await gate.wait(for: index)
            await operation()
        }
        tasks.append(task)
        return task
    }

    func release(_ index: Int) async {
        await gate.release(index)
    }
}
