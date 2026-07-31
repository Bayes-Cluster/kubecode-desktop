import AppKit
import SwiftUI
import Testing
@testable import KubecodeApp

@Suite(.serialized)
@MainActor
struct AppearancePreferencesTests {
    @Test func legacy_scale_and_invalid_values_normalize_to_native_defaults() {
        let legacy = WorkspaceTypography(fontName: "", pointSize: 1)
        let oversized = WorkspaceTypography(fontName: "System", pointSize: 21)

        #expect(legacy.fontName == WorkspaceTypography.systemFontName)
        #expect(legacy.pointSize == 14)
        #expect(oversized.pointSize == 14)
    }

    @Test func browser_compatible_ui_point_sizes_are_preserved() {
        for size in 12...20 {
            #expect(WorkspaceTypography(fontName: "System", pointSize: Double(size)).pointSize == Double(size))
        }
    }

    @Test func native_fonts_share_the_selected_family_and_body_size() {
        let family = "Helvetica Neue"
        let typography = WorkspaceTypography(fontName: family, pointSize: 16)
        let body = typography.nsFont(for: .body)
        let caption = typography.nsFont(for: .caption1)

        #expect(body.pointSize == 16)
        #expect(body.familyName == family)
        #expect(caption.pointSize < body.pointSize)
        #expect(typography.composerFont.pointSize == 16)
    }

    @Test func unavailable_ui_font_falls_back_to_the_system_family() {
        let typography = WorkspaceTypography(fontName: "Definitely Missing Kubecode Font", pointSize: 15)

        #expect(typography.nsFont(for: .body).familyName == NSFont.systemFont(ofSize: 15).familyName)
        #expect(typography.displayFontName == WorkspaceTypography.systemFontName)
    }

    @Test func native_composer_and_math_renderer_follow_workspace_typography() async throws {
        var text = "Use native text"
        var height = ComposerHeightCalculator.minimumHeight
        let typography = WorkspaceTypography(fontName: "Helvetica Neue", pointSize: 18)
        let controller = NSHostingController(rootView: VStack {
            NativeComposerTextView(
                text: Binding(get: { text }, set: { text = $0 }),
                height: Binding(get: { height }, set: { height = $0 }),
                onSubmit: {}
            )
            .frame(width: 360, height: 72)
            AgentMarkdownView(source: "Inline $x + y$ math")
                .frame(width: 360)
        }
        .workspaceTypography(typography)
        .frame(width: 420, height: 180))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        let composer = try #require(descendant(of: ComposerTextView.self, in: controller.view))
        let markdown = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        let renderDeadline = Date().addingTimeInterval(1)
        while markdown.renderedMathPointSizes.isEmpty, Date() < renderDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(composer.font?.familyName == "Helvetica Neue")
        #expect(composer.font?.pointSize == 18)
        #expect(markdown.renderedMathPointSizes == [18])
    }

    @Test func markdown_style_refresh_preserves_native_selection_and_focus() async throws {
        let source = "Stable **selection** with $x + y$."
        let store = AgentMarkdownRenderStore()
        let initialTypography = WorkspaceTypography(fontName: "System", pointSize: 14)
        let controller = NSHostingController(rootView: MarkdownAppearanceHarness(
            source: source,
            typography: initialTypography,
            tone: .primary,
            colorScheme: .light,
            store: store
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let textView = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        try await waitUntil {
            textView.renderedMathPointSizes == [14] && store.testingRowIDs.count == 1
        }
        let rowID = try #require(store.testingRowIDs.first)
        let initialInputs = try #require(store.latestRenderInputs(rowID: rowID))
        let initialHeight = try #require(store.heightCommit(
            rowID: rowID,
            width: 400,
            verticalInset: 4
        ))
        #expect(initialHeight.key.renderPublicationVersion
            == initialInputs.renderPublicationVersion)
        #expect(store.heightCommit(rowID: rowID, width: 400, verticalInset: 4)
            === initialHeight)
        let selection = try #require(textView.string.range(of: "selection"))
        let selectionRange = NSRange(selection, in: textView.string)
        textView.setSelectedRange(selectionRange)
        #expect(window.makeFirstResponder(textView))

        controller.rootView = MarkdownAppearanceHarness(
            source: source,
            typography: initialTypography,
            tone: .primary,
            colorScheme: .light,
            store: store
        )
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await mainQueueTurn() }
        #expect(store.latestRenderInputs(rowID: rowID) == initialInputs)
        #expect(store.heightCommit(rowID: rowID, width: 400, verticalInset: 4)
            === initialHeight)

        let largerTypography = WorkspaceTypography(fontName: "Helvetica Neue", pointSize: 18)
        controller.rootView = MarkdownAppearanceHarness(
            source: source,
            typography: largerTypography,
            tone: .primary,
            colorScheme: .light,
            store: store
        )
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        try await waitUntil {
            textView.renderedMathPointSizes == [18]
                && store.latestRenderInputs(rowID: rowID)?.renderPublicationVersion
                    == initialInputs.renderPublicationVersion + 1
        }
        let typographyInputs = try #require(store.latestRenderInputs(rowID: rowID))
        let typographyHeight = try #require(store.heightCommit(
            rowID: rowID,
            width: 400,
            verticalInset: 4
        ))
        #expect(typographyHeight !== initialHeight)
        #expect(typographyHeight.key.renderPublicationVersion
            == typographyInputs.renderPublicationVersion)

        controller.rootView = MarkdownAppearanceHarness(
            source: source,
            typography: largerTypography,
            tone: .secondary,
            colorScheme: .light,
            store: store
        )
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        try await waitUntil {
            store.latestRenderInputs(rowID: rowID)?.renderPublicationVersion
                == typographyInputs.renderPublicationVersion + 1
        }
        let toneInputs = try #require(store.latestRenderInputs(rowID: rowID))
        let toneHeight = try #require(store.heightCommit(
            rowID: rowID,
            width: 400,
            verticalInset: 4
        ))
        #expect(toneHeight !== typographyHeight)
        #expect(toneHeight.key.renderPublicationVersion == toneInputs.renderPublicationVersion)

        window.appearance = NSAppearance(named: .darkAqua)
        controller.rootView = MarkdownAppearanceHarness(
            source: source,
            typography: largerTypography,
            tone: .secondary,
            colorScheme: .dark,
            store: store
        )
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        try await waitUntil {
            store.latestRenderInputs(rowID: rowID)?.renderPublicationVersion
                == toneInputs.renderPublicationVersion + 1
        }
        let darkInputs = try #require(store.latestRenderInputs(rowID: rowID))
        let darkHeight = try #require(store.heightCommit(
            rowID: rowID,
            width: 400,
            verticalInset: 4
        ))
        #expect(darkHeight !== toneHeight)
        #expect(darkHeight.key.renderPublicationVersion == darkInputs.renderPublicationVersion)
        #expect(store.heightCommit(rowID: rowID, width: 400, verticalInset: 4)
            === darkHeight)

        let refreshed = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        #expect(refreshed === textView)
        #expect(refreshed.selectedRange() == selectionRange)
        #expect(window.firstResponder === refreshed)
        let stableRange = try #require(refreshed.string.range(of: "Stable"))
        let font = try #require(refreshed.attributedString().attribute(
            .font,
            at: NSRange(stableRange, in: refreshed.string).location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(font.familyName == "Helvetica Neue")
        #expect(font.pointSize == 18)
        let foreground = try #require(refreshed.attributedString().attribute(
            .foregroundColor,
            at: NSRange(stableRange, in: refreshed.string).location,
            effectiveRange: nil
        ) as? NSColor)
        #expect(foreground == NSColor.secondaryLabelColor)
        let layoutManager = try #require(refreshed.layoutManager)
        let textContainer = try #require(refreshed.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        #expect(ceil(usedRect.maxY) + refreshed.textContainerInset.height * 2
            <= darkHeight.height + 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for Markdown appearance refresh")
                return
            }
            await Task.yield()
        }
    }

    private func mainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func descendant<ViewType: NSView>(
        of type: ViewType.Type,
        in view: NSView
    ) -> ViewType? {
        if let match = view as? ViewType { return match }
        for child in view.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }
}

private struct MarkdownAppearanceHarness: View {
    let source: String
    let typography: WorkspaceTypography
    let tone: AgentMarkdownTone
    let colorScheme: ColorScheme
    let store: AgentMarkdownRenderStore

    var body: some View {
        AgentMarkdownView(source: source, tone: tone)
            .environment(\.agentMarkdownRenderStore, store)
            .workspaceTypography(typography)
            .environment(\.colorScheme, colorScheme)
            .frame(width: 400, height: 120, alignment: .topLeading)
    }
}
