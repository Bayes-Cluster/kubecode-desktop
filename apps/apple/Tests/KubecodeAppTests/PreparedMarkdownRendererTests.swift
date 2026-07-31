import AppKit
import KubecodeMarkdown
import KubecodeMacUI
import SwiftUI
import Testing
@testable import KubecodeApp

@Suite
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

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
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
    private(set) var callCount = 0

    init(data: Data) {
        self.data = data
    }

    func resolve() -> Data {
        callCount += 1
        return data
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
