import AppKit
import SwiftUI
import Testing
@testable import KubecodeApp
import KubecodeMacUI
import KubecodeUI

@Suite(.serialized)
struct StreamingTranscriptMarkdownTests {
    @Test @MainActor func active_output_renders_markdown_semantics_before_completion() async throws {
        let source = """
        # Active heading

        **Bold response** with `inlineCode` and [safe link](https://example.com).

        - first item
        - second item

        ```swift
        let value = 42
        ```

        | Name | Score |
        | :--- | ---: |
        | Ada | 42 |

        Math $x^2 + y^2$.
        """
        let hosted = try await host(output(source: source, phase: .update))
        defer { hosted.window.orderOut(nil) }
        let value = hosted.textView.attributedString()

        let heading = try #require(value.string.range(of: "Active heading"))
        let headingFont = try #require(value.attribute(
            .font,
            at: NSRange(heading, in: value.string).location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(headingFont.pointSize > 14)

        let bold = try #require(value.string.range(of: "Bold response"))
        let boldFont = try #require(value.attribute(
            .font,
            at: NSRange(bold, in: value.string).location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        let link = try #require(value.string.range(of: "safe link"))
        #expect(value.attribute(
            .link,
            at: NSRange(link, in: value.string).location,
            effectiveRange: nil
        ) as? URL == URL(string: "https://example.com"))
        #expect(value.string.contains("inlineCode"))
        #expect(value.string.contains("let value = 42"))
        #expect(value.string.contains("first item"))

        let tableCell = try #require(value.string.range(of: "Ada"))
        let tableStyle = try #require(value.attribute(
            .paragraphStyle,
            at: NSRange(tableCell, in: value.string).location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(!tableStyle.textBlocks.isEmpty)
        #expect(hosted.textView.renderedMathSources.contains("\\(x^2 + y^2\\)"))
    }

    @Test @MainActor func active_output_has_no_character_or_line_preview_cap() async throws {
        let lines = (1...8).map { index in
            "Line \(index): " + String(repeating: "界🙂", count: 18)
        }
        let source = lines.joined(separator: "\n") + "\nExact selectable tail"
        #expect(source.count > 220)
        let hosted = try await host(output(source: source, phase: .update), width: 420)
        defer { hosted.window.orderOut(nil) }

        #expect(hosted.textView.string.contains("Line 8:"))
        #expect(hosted.textView.string.contains("Exact selectable tail"))
        let tail = try #require(hosted.textView.string.range(of: "Exact selectable tail"))
        let tailRange = NSRange(tail, in: hosted.textView.string)
        hosted.textView.setSelectedRange(tailRange)
        #expect(hosted.textView.selectedRange() == tailRange)

        hosted.textView.layoutManager?.ensureLayout(for: hosted.textView.textContainer!)
        let glyphRange = hosted.textView.layoutManager?.glyphRange(
            forCharacterRange: tailRange,
            actualCharacterRange: nil
        ) ?? .init(location: 0, length: 0)
        let tailBounds = hosted.textView.layoutManager?.boundingRect(
            forGlyphRange: glyphRange,
            in: hosted.textView.textContainer!
        ) ?? .zero
        #expect(tailBounds.maxY > 3 * 14)
    }

    @Test @MainActor func active_copy_response_uses_complete_exact_source() async throws {
        let source = "  **Full raw response**\n" + String(repeating: "界🙂", count: 130) + "\n  tail  \n"
        let hosted = try await host(output(source: source, phase: .update))
        defer { hosted.window.orderOut(nil) }
        #expect(hosted.textView.copyResponseSource == source)

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(hosted.textView.menu(for: event))
        let copyResponse = try #require(menu.items.first {
            $0.identifier?.rawValue == WorkspaceAccessibilityAction.copyResponse.rawValue
        })
        NSPasteboard.general.clearContents()
        let action = try #require(copyResponse.action)
        #expect(NSApp.sendAction(action, to: copyResponse.target, from: copyResponse))
        #expect(NSPasteboard.general.string(forType: .string) == source)
    }

    @Test @MainActor func identical_source_update_to_final_retains_renderer_and_content_version() async throws {
        let source = "Same **complete** source"
        let update = output(
            source: source,
            phase: .update,
            sourceItemID: "stream-item",
            sourceMessageID: "stream-message"
        )
        let final = output(
            source: source,
            phase: .final,
            sourceItemID: "final-item",
            sourceMessageID: "final-message"
        )
        let updateIdentity = TranscriptRunOutputContentIdentity(output: update)
        let finalIdentity = TranscriptRunOutputContentIdentity(output: final)
        #expect(updateIdentity == finalIdentity)
        let changedIdentity = TranscriptRunOutputContentIdentity(output: output(
            source: source + " changed",
            phase: .update
        ))
        #expect(changedIdentity != updateIdentity)
        #expect(changedIdentity.contentRevision != updateIdentity.contentRevision)

        let previous = NativeTranscriptItem(
            id: update.id,
            contentRevision: updateIdentity.contentRevision
        )
        let current = NativeTranscriptItem(
            id: final.id,
            contentRevision: finalIdentity.contentRevision
        )
        #expect(TranscriptCollectionUpdatePlan.between(
            previous: [previous],
            current: [current]
        ) == .none)

        let controller = NSHostingController(rootView: TranscriptRunOutputRow(output: update))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(window: window, controller: controller)
        let firstView = try #require(firstSubview(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        try await waitForPreparedMarkdown(firstView, containing: "Same complete source")
        let firstStorage = try #require(firstView.textStorage)

        controller.rootView = TranscriptRunOutputRow(output: final)
        layout(window: window, controller: controller)
        await Task.yield()
        let finalView = try #require(firstSubview(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        #expect(finalView === firstView)
        #expect(finalView.textStorage === firstStorage)

        let session = AgentMarkdownRenderSession()
        let typography = WorkspaceTypography(fontName: "System", pointSize: 14)
        #expect(session.submit(
            source: source,
            generation: 1,
            typography: typography,
            tone: .primary
        ) == .accepted(contentVersion: 1))
        try await waitUntil { session.latestCommit != nil }
        let identity = session.identity
        let commit = try #require(session.latestCommit)
        let preparationCount = session.preparationCount
        #expect(session.submit(
            source: source,
            generation: 2,
            typography: typography,
            tone: .primary
        ) == .unchanged(contentVersion: 1))
        #expect(session.identity == identity)
        #expect(session.latestCommit === commit)
        #expect(session.latestContentVersion == 1)
        #expect(session.preparationCount == preparationCount)
    }

    private func output(
        source: String,
        phase: TranscriptRunOutputPhase,
        sourceItemID: String = "item",
        sourceMessageID: String? = "message"
    ) -> TranscriptRunOutput {
        TranscriptRunOutput(
            runID: "run-1",
            text: source,
            phase: phase,
            sourceItemID: sourceItemID,
            sourceMessageID: sourceMessageID
        )
    }

    @MainActor
    private func host(
        _ output: TranscriptRunOutput,
        width: CGFloat = 760
    ) async throws -> (
        controller: NSHostingController<TranscriptRunOutputRow>,
        window: NSWindow,
        textView: NativeAgentMarkdownTextView
    ) {
        let controller = NSHostingController(rootView: TranscriptRunOutputRow(output: output))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        layout(window: window, controller: controller)
        let textView = try #require(firstSubview(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        try await waitUntil { textView.attributedString().length > 0 }
        layout(window: window, controller: controller)
        return (controller, window, textView)
    }

    @MainActor
    private func layout(
        window: NSWindow,
        controller: NSViewController
    ) {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { firstSubview(of: type, in: $0) }.first
    }

    @MainActor
    private func waitForPreparedMarkdown(
        _ textView: NativeAgentMarkdownTextView,
        containing expected: String,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await waitUntil(timeout: timeout) {
            textView.string.contains(expected.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
                Issue.record("Timed out waiting for prepared Markdown")
                return
            }
            await Task.yield()
        }
    }
}
