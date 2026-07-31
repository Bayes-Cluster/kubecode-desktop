import AppKit
import SwiftUI
import Testing
@testable import KubecodeApp

@MainActor
private final class WheelCountingScrollView: NSScrollView {
    private(set) var wheelEventCount = 0

    override func scrollWheel(with event: NSEvent) {
        wheelEventCount += 1
    }
}

@Suite(.serialized)
@MainActor
struct BoundedTranscriptDisclosureTests {
    @Test func disclosure_caps_are_exact() {
        #expect(TranscriptDisclosureMetrics.workingMaximumHeight == 320)
        #expect(TranscriptDisclosureMetrics.toolOutputMaximumHeight == 220)
        #expect(BoundedTranscriptHeight.resolve(contentHeight: 480, maximumHeight: 320) == 320)
        #expect(BoundedTranscriptHeight.resolve(contentHeight: 180, maximumHeight: 220) == 180)
    }

    @Test func boundary_wheel_is_forwarded_once_to_the_nearest_parent() throws {
        let parent = WheelCountingScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let parentDocument = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
        parent.documentView = parentDocument

        let child = BoundaryForwardingScrollView(
            frame: NSRect(x: 0, y: 100, width: 260, height: 120)
        )
        let childDocument = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        child.documentView = childDocument
        parentDocument.addSubview(child)
        child.contentView.scroll(to: NSPoint(x: 0, y: child.maximumVerticalOrigin))

        #expect(child.nearestParentScrollView === parent)
        let event = try #require(scrollWheelEvent(deltaY: -24))
        child.scrollWheel(with: event)

        #expect(parent.wheelEventCount == 1)
    }

    @Test func consumable_wheel_stays_in_the_inner_view() throws {
        let parent = WheelCountingScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let parentDocument = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
        parent.documentView = parentDocument

        let child = BoundaryForwardingScrollView(
            frame: NSRect(x: 0, y: 100, width: 260, height: 120)
        )
        child.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        parentDocument.addSubview(child)
        child.contentView.scroll(to: NSPoint(x: 0, y: 100))

        child.scrollWheel(with: try #require(scrollWheelEvent(deltaY: -24)))

        #expect(parent.wheelEventCount == 0)
    }

    @Test func working_content_is_bounded_to_320_points() async throws {
        let controller = NSHostingController(rootView:
            NativeBoundedTranscriptView(maximumHeight: TranscriptDisclosureMetrics.workingMaximumHeight) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<40, id: \.self) { index in
                        Text("Working detail \(index)")
                    }
                }
            }
            .frame(width: 360)
        )
        let window = mountedWindow(controller: controller, size: NSSize(width: 360, height: 500))
        defer { window.orderOut(nil) }
        await settle(window: window)

        let bounded = try #require(descendant(
            of: NativeBoundedTranscriptNSView.self,
            in: controller.view
        ))
        #expect(abs(bounded.frame.height - 320) < 1)
        #expect(bounded.contentHeight > bounded.frame.height)
    }

    @Test func tool_output_is_exact_selectable_textkit_bounded_to_220_points() async throws {
        let output = (0..<80).map { "tool-output-\($0)" }.joined(separator: "\n")
        let controller = NSHostingController(rootView:
            NativeSelectableToolOutputView(source: output)
                .frame(width: 340)
        )
        let window = mountedWindow(controller: controller, size: NSSize(width: 340, height: 360))
        defer { window.orderOut(nil) }
        await settle(window: window)

        let textView = try #require(descendant(of: NativeToolOutputTextView.self, in: controller.view))
        let scrollView = try #require(textView.enclosingScrollView as? BoundaryForwardingScrollView)
        #expect(textView.string == output)
        #expect(abs(scrollView.frame.height - 220) < 1)
        #expect(textView.frame.height > scrollView.frame.height)

        let selection = (output as NSString).range(of: "tool-output-17\ntool-output-18")
        textView.setSelectedRange(selection)
        textView.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "tool-output-17\ntool-output-18")
    }

    @Test func short_tool_output_uses_its_exact_intrinsic_space() async throws {
        let output = "first\nsecond"
        let controller = NSHostingController(rootView:
            NativeSelectableToolOutputView(source: output)
                .frame(width: 340)
        )
        let window = mountedWindow(controller: controller, size: NSSize(width: 340, height: 300))
        defer { window.orderOut(nil) }
        await settle(window: window)

        let textView = try #require(descendant(of: NativeToolOutputTextView.self, in: controller.view))
        let scrollView = try #require(textView.enclosingScrollView)
        #expect(scrollView.frame.height < 220)
        #expect(abs(scrollView.frame.height - textView.frame.height) < 1)
    }

    private func mountedWindow<Content: View>(
        controller: NSHostingController<Content>,
        size: NSSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(window: NSWindow) async {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            await Task.yield()
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

    private func scrollWheelEvent(deltaY: Int32) -> NSEvent? {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        )
        return event.flatMap(NSEvent.init(cgEvent:))
    }
}
