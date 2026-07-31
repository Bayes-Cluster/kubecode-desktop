import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import KubecodeApp

#if os(macOS)
@Suite(.serialized)
@MainActor
struct ComposerMeasurementTests {
    @Test func compact_and_expanded_presentations_use_the_same_editor_width() throws {
        let compact = try mountedEditorWidth(expanded: false)
        let expanded = try mountedEditorWidth(expanded: true)

        #expect(compact == expanded)
        #expect(compact == 492)
    }

    @Test func append_only_drafts_grow_monotonically_until_the_scroll_cap() {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let fragments = Array(repeating: "wrapped composer content ", count: 80)
        var draft = ""
        var heights: [CGFloat] = []

        for fragment in fragments {
            draft += fragment
            heights.append(ComposerHeightCalculator.height(
                for: draft,
                width: 240,
                font: font
            ))
        }

        #expect(zip(heights, heights.dropFirst()).allSatisfy(<=))
        #expect(heights.last == ComposerHeightCalculator.maximumHeight)
        #expect(heights.allSatisfy {
            $0 >= ComposerHeightCalculator.minimumHeight
                && $0 <= ComposerHeightCalculator.maximumHeight
        })
    }

    @Test func identical_measurement_input_is_a_strict_no_op() throws {
        var state = ComposerMeasurementState()
        let input = ComposerMeasurementInput(
            text: "same draft",
            width: 320,
            fontName: "Helvetica",
            fontSize: 13
        )
        let pendingRequest = state.request(input)
        let request = try #require(pendingRequest)

        let duplicatePendingRequest = state.request(input)
        #expect(duplicatePendingRequest == nil)
        #expect(state.scheduledMeasurementCount == 1)
        let didCommit = state.commit(request, height: 48)
        #expect(didCommit)
        let duplicateCommittedRequest = state.request(input)
        #expect(duplicateCommittedRequest == nil)
        #expect(state.scheduledMeasurementCount == 1)
        #expect(state.completedMeasurementCount == 1)
        #expect(state.committedHeight == 48)
    }

    @Test func delayed_old_width_cannot_replace_a_newer_measurement() throws {
        var state = ComposerMeasurementState()
        let oldRequest = state.request(ComposerMeasurementInput(
            text: "draft",
            width: 280,
            fontName: "Helvetica",
            fontSize: 13
        ))
        let old = try #require(oldRequest)
        let currentRequest = state.request(ComposerMeasurementInput(
            text: "draft",
            width: 420,
            fontName: "Helvetica",
            fontSize: 13
        ))
        let current = try #require(currentRequest)

        let acceptedOld = state.commit(old, height: 72)
        #expect(!acceptedOld)
        #expect(state.committedHeight == nil)
        let acceptedCurrent = state.commit(current, height: 48)
        #expect(acceptedCurrent)
        #expect(state.committedHeight == 48)
        #expect(state.completedMeasurementCount == 1)
        #expect(state.rejectedMeasurementCount == 1)
    }

    @Test func entering_and_leaving_scroll_cap_does_not_change_wrapping_width() throws {
        var measuredHeight = ComposerHeightCalculator.minimumHeight
        let scrollView = ComposerScrollView()
        let textView = ComposerTextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.string = String(repeating: "A capped composer line. ", count: 80)
        scrollView.documentView = textView
        scrollView.heightBinding = Binding(
            get: { measuredHeight },
            set: { measuredHeight = $0 }
        )
        scrollView.setFrameSize(NSSize(width: 320, height: 72))

        scrollView.scheduleMeasurement()
        try #require(scrollView.performPendingMeasurement())
        let cappedWidth = try #require(scrollView.committedMeasurementInput?.width)
        #expect(measuredHeight == ComposerHeightCalculator.maximumHeight)
        #expect(scrollView.hasVerticalScroller)

        textView.string = "short"
        scrollView.scheduleMeasurement()
        try #require(scrollView.performPendingMeasurement())

        #expect(measuredHeight == ComposerHeightCalculator.minimumHeight)
        #expect(!scrollView.hasVerticalScroller)
        #expect(scrollView.committedMeasurementInput?.width == cappedWidth)
        #expect(textView.textContainer?.containerSize.width == cappedWidth)
    }

    @Test func width_change_preserves_editor_identity_focus_selection_and_marked_text() throws {
        var draft = "prefix selected suffix"
        var measuredHeight = ComposerHeightCalculator.minimumHeight
        let controller = NSHostingController(rootView: NativeComposerTextView(
            text: Binding(get: { draft }, set: { draft = $0 }),
            height: Binding(get: { measuredHeight }, set: { measuredHeight = $0 }),
            onSubmit: {}
        ).frame(width: 320, height: ComposerHeightCalculator.maximumHeight))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let textView = try #require(descendant(of: ComposerTextView.self, in: controller.view))
        let identity = ObjectIdentifier(textView)
        let selection = NSRange(location: 7, length: 8)
        textView.setSelectedRange(selection)
        #expect(window.makeFirstResponder(textView))
        textView.setMarkedText(
            "marked",
            selectedRange: NSRange(location: 6, length: 0),
            replacementRange: selection
        )
        let markedRange = textView.markedRange()
        let selectionAfterMarking = textView.selectedRange()

        window.setContentSize(NSSize(width: 520, height: 120))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let resizedTextView = try #require(descendant(
            of: ComposerTextView.self,
            in: controller.view
        ))
        #expect(ObjectIdentifier(resizedTextView) == identity)
        #expect(window.firstResponder === resizedTextView)
        #expect(resizedTextView.selectedRange() == selectionAfterMarking)
        #expect(resizedTextView.markedRange() == markedRange)
        #expect(resizedTextView.hasMarkedText())
    }

    private func descendant<ViewType: NSView>(
        of type: ViewType.Type,
        in root: NSView
    ) -> ViewType? {
        if let match = root as? ViewType { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

    private func mountedEditorWidth(expanded: Bool) throws -> CGFloat {
        var draft = "Composer width"
        var measuredHeight = ComposerHeightCalculator.minimumHeight
        let controller = NSHostingController(rootView: NativeComposerLayout(expanded: expanded) {
            Color.clear.frame(width: 32, height: 32)
            NativeComposerTextView(
                text: Binding(get: { draft }, set: { draft = $0 }),
                height: Binding(get: { measuredHeight }, set: { measuredHeight = $0 }),
                onSubmit: {}
            )
            .frame(height: measuredHeight)
            Color.clear.frame(width: 148, height: 40)
        }
        .frame(width: 720))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let scrollView = try #require(descendant(of: ComposerScrollView.self, in: controller.view))
        return scrollView.frame.width
    }
}
#endif
