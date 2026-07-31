#if os(macOS)
import AppKit
import SwiftUI

enum ComposerHeightCalculator {
    static let minimumHeight: CGFloat = 36
    static let maximumHeight: CGFloat = 72

    static func height(for text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty, width > 40 else { return minimumHeight }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let measured = ceil(bounds.height) + 12
        return min(max(measured, minimumHeight), maximumHeight)
    }
}

enum ComposerPresentationMetrics {
    static let verticalInset: CGFloat = 10
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 10
    static let controlSpacing: CGFloat = 12
    static let expandedRowSpacing: CGFloat = 6
    static let controlRowHeight: CGFloat = 40
    static let transitionDuration = 0.22

    static func barHeight(contentHeight: CGFloat) -> CGFloat {
        contentHeight + (verticalInset * 2)
    }

    static func expandedBarHeight(contentHeight: CGFloat) -> CGFloat {
        verticalInset + contentHeight + expandedRowSpacing + controlRowHeight + verticalInset
    }

    static func effectiveEditorWidth(
        totalWidth: CGFloat,
        contextWidth: CGFloat,
        trailingWidth: CGFloat
    ) -> CGFloat {
        max(
            40,
            totalWidth
                - leadingInset
                - trailingInset
                - contextWidth
                - trailingWidth
                - (controlSpacing * 2)
        )
    }

    static func primaryActionIsProminent(
        hasActiveRun: Bool,
        hasSendableText: Bool
    ) -> Bool {
        hasActiveRun || hasSendableText
    }

    static func agentDisclosureRotation(isPresented: Bool) -> Double {
        isPresented ? 180 : 0
    }

    static func shouldUseExpandedLayout(
        measuredHeight: CGFloat,
        stateRequested: Bool
    ) -> Bool {
        stateRequested || measuredHeight > ComposerHeightCalculator.minimumHeight + 0.5
    }
}

struct ComposerMeasurementInput: Equatable {
    let text: String
    let width: CGFloat
    let fontName: String
    let fontSize: CGFloat
}

struct ComposerMeasurementRequest: Equatable {
    let generation: Int
    let input: ComposerMeasurementInput
}

struct ComposerMeasurementState {
    private(set) var latestRequest: ComposerMeasurementRequest?
    private(set) var committedInput: ComposerMeasurementInput?
    private(set) var committedHeight: CGFloat?
    private(set) var scheduledMeasurementCount = 0
    private(set) var completedMeasurementCount = 0
    private(set) var rejectedMeasurementCount = 0
    private var nextGeneration = 0

    mutating func request(_ input: ComposerMeasurementInput) -> ComposerMeasurementRequest? {
        if let latestRequest {
            guard latestRequest.input != input else { return nil }
        } else if committedInput == input {
            return nil
        }

        nextGeneration += 1
        let request = ComposerMeasurementRequest(generation: nextGeneration, input: input)
        latestRequest = request
        scheduledMeasurementCount += 1
        return request
    }

    mutating func shouldMeasure(_ request: ComposerMeasurementRequest) -> Bool {
        guard latestRequest == request else {
            rejectedMeasurementCount += 1
            return false
        }
        return true
    }

    mutating func commit(_ request: ComposerMeasurementRequest, height: CGFloat) -> Bool {
        guard latestRequest == request else {
            rejectedMeasurementCount += 1
            return false
        }
        latestRequest = nil
        committedInput = request.input
        committedHeight = height
        completedMeasurementCount += 1
        return true
    }
}

enum ComposerCommandCompletion {
    static func isDeletion(affectedRange: NSRange, replacementString: String?) -> Bool {
        affectedRange.length > 0 && replacementString?.isEmpty == true
    }

    static func range(in text: String, caretUTF16Location: Int) -> NSRange? {
        let utf16Count = text.utf16.count
        guard caretUTF16Location > 0,
              caretUTF16Location <= utf16Count,
              caretUTF16Location == utf16Count
        else { return nil }
        let prefix = (text as NSString).substring(to: caretUTF16Location)
        guard prefix.first == "/",
              !prefix.dropFirst().contains(where: { $0.isWhitespace })
        else { return nil }
        return NSRange(location: 0, length: caretUTF16Location)
    }

    static func candidates(
        in text: String,
        caretUTF16Location: Int,
        commands: [NativeCommand]
    ) -> [String] {
        guard let range = range(in: text, caretUTF16Location: caretUTF16Location) else { return [] }
        let prefix = (text as NSString).substring(with: range)
        return commands
            .map { "/\($0.name)" }
            .filter {
                $0.range(
                    of: prefix,
                    options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
    }
}

enum ComposerDraftSynchronization {
    static func shouldApplyExternalText(_ externalText: String, lastNativeText: String) -> Bool {
        externalText != lastNativeText
    }

    static func selectionAfterExternalUpdate(
        previousSelection: NSRange,
        previousUTF16Length: Int,
        newUTF16Length: Int
    ) -> NSRange {
        if previousSelection.length == 0,
           previousSelection.location == previousUTF16Length {
            return NSRange(location: newUTF16Length, length: 0)
        }
        let location = min(previousSelection.location, newUTF16Length)
        let length = min(previousSelection.length, newUTF16Length - location)
        return NSRange(location: location, length: length)
    }
}

final class ComposerTextView: NSTextView {
    var commands: [NativeCommand] = []

    override var rangeForUserCompletion: NSRange {
        ComposerCommandCompletion.range(
            in: string,
            caretUTF16Location: selectedRange().location
        ) ?? NSRange(location: NSNotFound, length: 0)
    }

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let candidates = ComposerCommandCompletion.candidates(
            in: string,
            caretUTF16Location: NSMaxRange(charRange),
            commands: commands
        )
        if !candidates.isEmpty { index.pointee = 0 }
        return candidates
    }
}

struct NativeComposerLayout: Layout {
    let expanded: Bool

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let controls = [
            subviews[0].sizeThatFits(.unspecified),
            subviews[2].sizeThatFits(.unspecified),
        ]
        let intrinsicWidth = controls.reduce(0) { $0 + $1.width }
            + ComposerPresentationMetrics.leadingInset
            + ComposerPresentationMetrics.trailingInset
            + (ComposerPresentationMetrics.controlSpacing * CGFloat(controls.count))
            + 240
        let width = proposal.width ?? intrinsicWidth
        let editorWidth = ComposerPresentationMetrics.effectiveEditorWidth(
            totalWidth: width,
            contextWidth: controls[0].width,
            trailingWidth: controls[1].width
        )
        let editor = subviews[1].sizeThatFits(ProposedViewSize(width: editorWidth, height: nil))
        let height = expanded
            ? ComposerPresentationMetrics.expandedBarHeight(contentHeight: editor.height)
            : ComposerPresentationMetrics.barHeight(contentHeight: editor.height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 3 else { return }
        let contextSize = subviews[0].sizeThatFits(.unspecified)
        let trailingSize = subviews[2].sizeThatFits(.unspecified)
        let editorWidth = ComposerPresentationMetrics.effectiveEditorWidth(
            totalWidth: bounds.width,
            contextWidth: contextSize.width,
            trailingWidth: trailingSize.width
        )
        let editorX = bounds.minX
            + ComposerPresentationMetrics.leadingInset
            + contextSize.width
            + ComposerPresentationMetrics.controlSpacing

        if expanded {
            let editorSize = subviews[1].sizeThatFits(ProposedViewSize(
                width: editorWidth,
                height: nil
            ))
            subviews[1].place(
                at: CGPoint(
                    x: editorX,
                    y: bounds.minY + ComposerPresentationMetrics.verticalInset
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: editorWidth, height: editorSize.height)
            )
            let controlY = bounds.maxY
                - ComposerPresentationMetrics.verticalInset
                - (ComposerPresentationMetrics.controlRowHeight / 2)
            subviews[0].place(
                at: CGPoint(
                    x: bounds.minX + ComposerPresentationMetrics.leadingInset,
                    y: controlY
                ),
                anchor: .leading,
                proposal: ProposedViewSize(contextSize)
            )
            subviews[2].place(
                at: CGPoint(
                    x: bounds.maxX - ComposerPresentationMetrics.trailingInset,
                    y: controlY
                ),
                anchor: .trailing,
                proposal: ProposedViewSize(trailingSize)
            )
            return
        }

        var x = bounds.minX + ComposerPresentationMetrics.leadingInset
        subviews[0].place(
            at: CGPoint(x: x, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(contextSize)
        )
        x += contextSize.width + ComposerPresentationMetrics.controlSpacing
        subviews[1].place(
            at: CGPoint(x: x, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: editorWidth, height: nil)
        )
        x += editorWidth + ComposerPresentationMetrics.controlSpacing
        subviews[2].place(
            at: CGPoint(x: x, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(trailingSize)
        )
    }
}

struct NativeComposerTextView: NSViewRepresentable {
    @Environment(\.workspaceTypography) private var typography
    @Binding var text: String
    @Binding var height: CGFloat
    var commands: [NativeCommand] = []
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.commands = commands
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = typography.composerFont
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = text

        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.heightBinding = $height
        context.coordinator.textView = textView
        scrollView.scheduleMeasurement()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let composerScrollView = scrollView as? ComposerScrollView {
            composerScrollView.heightBinding = $height
        }
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        textView.commands = commands
        if textView.font != typography.composerFont {
            textView.font = typography.composerFont
        }
        if ComposerDraftSynchronization.shouldApplyExternalText(
            text,
            lastNativeText: context.coordinator.lastNativeText
        ) {
            let previousLength = textView.string.utf16.count
            let previousSelection = textView.selectedRange()
            context.coordinator.lastNativeText = text
            textView.string = text
            textView.setSelectedRange(ComposerDraftSynchronization.selectionAfterExternalUpdate(
                previousSelection: previousSelection,
                previousUTF16Length: previousLength,
                newUTF16Length: text.utf16.count
            ))
        }
        (scrollView as? ComposerScrollView)?.scheduleMeasurement()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerTextView
        weak var textView: NSTextView?
        var lastNativeText: String
        private(set) var completionRequestPending = false
        private var suppressNextCompletion = false
        private var completionGeneration = 0

        init(parent: NativeComposerTextView) {
            self.parent = parent
            lastNativeText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            lastNativeText = textView.string
            parent.text = textView.string
            updateHeight()
            if suppressNextCompletion {
                suppressNextCompletion = false
                return
            }
            requestCommandCompletion(for: textView)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if ComposerCommandCompletion.isDeletion(
                affectedRange: affectedCharRange,
                replacementString: replacementString
            ) {
                suppressNextCompletion = true
                completionGeneration += 1
            }
            return true
        }

        private func requestCommandCompletion(for textView: NSTextView) {
            guard !completionRequestPending,
                  !ComposerCommandCompletion.candidates(
                    in: textView.string,
                    caretUTF16Location: textView.selectedRange().location,
                    commands: parent.commands
                  ).isEmpty
            else { return }
            completionRequestPending = true
            let generation = completionGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                defer { self?.completionRequestPending = false }
                guard let self,
                      generation == self.completionGeneration,
                      let textView,
                      textView.window?.firstResponder === textView,
                      !ComposerCommandCompletion.candidates(
                        in: textView.string,
                        caretUTF16Location: textView.selectedRange().location,
                        commands: self.parent.commands
                      ).isEmpty
                else { return }
                textView.complete(nil)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            guard !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func updateHeight() {
            (textView?.enclosingScrollView as? ComposerScrollView)?.scheduleMeasurement()
        }
    }
}

final class ComposerScrollView: NSScrollView {
    var heightBinding: Binding<CGFloat>?
    private var measurementState = ComposerMeasurementState()

    var completedMeasurementCount: Int {
        measurementState.completedMeasurementCount
    }

    var committedMeasurementInput: ComposerMeasurementInput? {
        measurementState.committedInput
    }

    override func layout() {
        super.layout()
        scheduleMeasurement()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleMeasurement()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleMeasurement()
    }

    func scheduleMeasurement() {
        guard let input = measurementInput(),
              let request = measurementState.request(input)
        else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.measure(request)
        }
    }

    @discardableResult
    func performPendingMeasurement() -> Bool {
        guard let request = measurementState.latestRequest else { return false }
        return measure(request)
    }

    private func measurementInput() -> ComposerMeasurementInput? {
        guard let textView = documentView as? NSTextView,
              heightBinding != nil
        else { return nil }
        let width = bounds.width
        guard width > 40 else { return nil }
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        return ComposerMeasurementInput(
            text: textView.string,
            width: width,
            fontName: font.fontName,
            fontSize: font.pointSize
        )
    }

    private func measure(_ request: ComposerMeasurementRequest) -> Bool {
        guard measurementState.shouldMeasure(request),
              let textView = documentView as? NSTextView,
              let textContainer = textView.textContainer,
              let heightBinding
        else { return false }
        guard measurementInput() == request.input else {
            scheduleMeasurement()
            return false
        }

        let input = request.input
        if abs(textView.frame.width - input.width) > 0.5 {
            textView.setFrameSize(NSSize(width: input.width, height: textView.frame.height))
        }
        let containerSize = NSSize(
            width: input.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        if textContainer.containerSize != containerSize {
            textContainer.containerSize = containerSize
        }
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let nextHeight = ComposerHeightCalculator.height(
            for: input.text,
            width: input.width,
            font: font
        )
        guard measurementState.commit(request, height: nextHeight) else { return false }
        apply(height: nextHeight, to: heightBinding)
        return true
    }

    private func apply(height: CGFloat, to heightBinding: Binding<CGFloat>) {
        let needsScroller = height >= ComposerHeightCalculator.maximumHeight
        if hasVerticalScroller != needsScroller {
            hasVerticalScroller = needsScroller
        }
        guard abs(heightBinding.wrappedValue - height) > 0.5 else { return }
        heightBinding.wrappedValue = height
    }
}
#endif
