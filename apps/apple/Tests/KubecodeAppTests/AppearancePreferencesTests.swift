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

    @Test func native_composer_and_math_renderer_follow_workspace_typography() throws {
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let composer = try #require(descendant(of: ComposerTextView.self, in: controller.view))
        let markdown = try #require(descendant(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        #expect(composer.font?.familyName == "Helvetica Neue")
        #expect(composer.font?.pointSize == 18)
        #expect(markdown.renderedMathPointSizes == [18])
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
