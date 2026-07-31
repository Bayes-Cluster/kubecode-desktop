import AppKit
import SwiftUI

enum TranscriptDisclosureMetrics {
    static let workingMaximumHeight: CGFloat = 320
    static let toolOutputMaximumHeight: CGFloat = 220
}

enum BoundedTranscriptHeight {
    static func resolve(contentHeight: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        min(max(1, ceil(contentHeight)), maximumHeight)
    }
}

@MainActor
final class BoundaryForwardingScrollView: NSScrollView {
    var maximumVerticalOrigin: CGFloat {
        max(0, (documentView?.bounds.height ?? 0) - documentVisibleRect.height)
    }

    var nearestParentScrollView: NSScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView, scrollView !== self {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard !canConsume(deltaY: event.scrollingDeltaY),
              let nearestParentScrollView
        else {
            super.scrollWheel(with: event)
            return
        }
        nearestParentScrollView.scrollWheel(with: event)
    }

    private func canConsume(deltaY: CGFloat) -> Bool {
        guard maximumVerticalOrigin > 0.5 else { return false }
        let originY = documentVisibleRect.minY
        if deltaY > 0 { return originY > 0.5 }
        if deltaY < 0 { return originY < maximumVerticalOrigin - 0.5 }
        return true
    }
}

@MainActor
final class NativeBoundedTranscriptNSView: NSView {
    let scrollView = BoundaryForwardingScrollView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var content = AnyView(EmptyView())
    private(set) var maximumHeight: CGFloat
    private(set) var contentHeight: CGFloat = 1
    private var measuredWidth: CGFloat = 1

    init(maximumHeight: CGFloat) {
        self.maximumHeight = maximumHeight
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = hostingView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, maximumHeight: CGFloat) {
        self.content = content
        self.maximumHeight = maximumHeight
        _ = measure(width: max(bounds.width, measuredWidth))
        needsLayout = true
    }

    func measure(width: CGFloat) -> NSSize {
        let exactWidth = max(1, width)
        measuredWidth = exactWidth
        hostingView.rootView = AnyView(
            content
                .frame(width: exactWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: exactWidth, height: 10_000)
        contentHeight = max(1, ceil(hostingView.fittingSize.height))
        hostingView.frame = NSRect(x: 0, y: 0, width: exactWidth, height: contentHeight)
        scrollView.hasVerticalScroller = contentHeight > maximumHeight + 0.5
        return NSSize(
            width: exactWidth,
            height: BoundedTranscriptHeight.resolve(
                contentHeight: contentHeight,
                maximumHeight: maximumHeight
            )
        )
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let exactWidth = max(1, scrollView.contentSize.width)
        if abs(exactWidth - measuredWidth) >= 0.5 {
            _ = measure(width: exactWidth)
        }
        hostingView.frame.size = NSSize(width: exactWidth, height: contentHeight)
    }
}

@MainActor
struct NativeBoundedTranscriptView<Content: View>: NSViewRepresentable {
    let maximumHeight: CGFloat
    private let content: Content

    init(
        maximumHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.maximumHeight = maximumHeight
        self.content = content()
    }

    func makeNSView(context: Context) -> NativeBoundedTranscriptNSView {
        let view = NativeBoundedTranscriptNSView(maximumHeight: maximumHeight)
        view.update(content: AnyView(content), maximumHeight: maximumHeight)
        return view
    }

    func updateNSView(_ nsView: NativeBoundedTranscriptNSView, context: Context) {
        nsView.update(content: AnyView(content), maximumHeight: maximumHeight)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeBoundedTranscriptNSView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        return nsView.measure(width: width)
    }
}

@MainActor
final class NativeToolOutputTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

@MainActor
struct NativeSelectableToolOutputView: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> BoundaryForwardingScrollView {
        let scrollView = BoundaryForwardingScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = NativeToolOutputTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        textView.textColor = .secondaryLabelColor
        textView.string = source
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: BoundaryForwardingScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NativeToolOutputTextView else { return }
        if textView.string != source {
            let selection = textView.selectedRange()
            textView.string = source
            if selection.location != NSNotFound,
               NSMaxRange(selection) <= (source as NSString).length {
                textView.setSelectedRange(selection)
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: BoundaryForwardingScrollView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 1,
              let textView = scrollView.documentView as? NativeToolOutputTextView
        else { return nil }
        let exactWidth = max(1, width)
        let contentHeight = measure(textView: textView, width: exactWidth)
        scrollView.hasVerticalScroller = contentHeight
            > TranscriptDisclosureMetrics.toolOutputMaximumHeight + 0.5
        return CGSize(
            width: exactWidth,
            height: BoundedTranscriptHeight.resolve(
                contentHeight: contentHeight,
                maximumHeight: TranscriptDisclosureMetrics.toolOutputMaximumHeight
            )
        )
    }

    private func measure(textView: NativeToolOutputTextView, width: CGFloat) -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return 1 }
        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = max(1, ceil(used.height + textView.textContainerInset.height * 2))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return height
    }
}
