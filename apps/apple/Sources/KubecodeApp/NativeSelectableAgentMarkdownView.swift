import AppKit
import SwiftUI

enum AgentMarkdownTone: Equatable {
    case primary
    case secondary
}

private extension NSAttributedString.Key {
    static let kubecodeMathSource = NSAttributedString.Key("dev.kubecode.math-source")
    static let kubecodeMathPointSize = NSAttributedString.Key("dev.kubecode.math-point-size")
}

final class NativeAgentMarkdownTextView: NSTextView {
    var copyResponseSource: String?

    var renderedMathSources: [String] {
        var sources: [String] = []
        attributedString().enumerateAttribute(
            .kubecodeMathSource,
            in: NSRange(location: 0, length: attributedString().length)
        ) { value, _, _ in
            if let source = value as? String { sources.append(source) }
        }
        return sources
    }

    var renderedMathPointSizes: [CGFloat] {
        var sizes: [CGFloat] = []
        attributedString().enumerateAttribute(
            .kubecodeMathPointSize,
            in: NSRange(location: 0, length: attributedString().length)
        ) { value, _, _ in
            if let size = value as? CGFloat { sizes.append(size) }
        }
        return sizes
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.location != NSNotFound,
              selection.length > 0,
              NSMaxRange(selection) <= attributedString().length
        else {
            super.copy(sender)
            return
        }

        let selected = NSMutableAttributedString(
            attributedString: attributedString().attributedSubstring(from: selection)
        )
        var replacements: [(NSRange, String)] = []
        selected.enumerateAttribute(
            .kubecodeMathSource,
            in: NSRange(location: 0, length: selected.length)
        ) { value, range, _ in
            if let source = value as? String {
                replacements.append((range, source))
            }
        }
        for (range, source) in replacements.reversed() {
            selected.replaceCharacters(in: range, with: source)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.string, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let identifier = NSUserInterfaceItemIdentifier(
            WorkspaceAccessibilityAction.copyResponse.rawValue
        )
        guard copyResponseSource?.isEmpty == false,
              !menu.items.contains(where: { $0.identifier == identifier })
        else { return menu }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: String(localized: "Copy Response"),
            action: #selector(copyResponse(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.identifier = identifier
        item.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: String(localized: "Copy Response")
        )
        menu.addItem(item)
        return menu
    }

    @objc private func copyResponse(_ sender: Any?) {
        guard let copyResponseSource else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyResponseSource, forType: .string)
    }
}

struct NativeSelectableAgentMarkdownView: NSViewRepresentable {
    let source: String
    let typography: WorkspaceTypography
    let tone: AgentMarkdownTone
    let copyResponseSource: String?

    @MainActor
    final class Coordinator {
        private var renderedKey: RenderedKey?
        private var renderedValue: NSAttributedString?
        private var appliedKey: RenderedKey?
        private var measuredWidth: CGFloat?
        private var measuredHeight: CGFloat?
        private(set) var renderCount = 0
        private(set) var applyCount = 0

        func rendered(
            source: String,
            typography: WorkspaceTypography,
            tone: AgentMarkdownTone
        ) -> NSAttributedString {
            let key = RenderedKey(source: source, typography: typography, tone: tone)
            if renderedKey == key, let renderedValue {
                return renderedValue
            }
            let value = NativeAgentMarkdownRenderer.render(
                AgentMarkdownDocument(source: source),
                typography: typography,
                tone: tone
            )
            renderedKey = key
            renderedValue = value
            measuredWidth = nil
            measuredHeight = nil
            renderCount += 1
            return value
        }

        func renderedUpdate(
            source: String,
            typography: WorkspaceTypography,
            tone: AgentMarkdownTone
        ) -> NSAttributedString? {
            let key = RenderedKey(source: source, typography: typography, tone: tone)
            guard appliedKey != key else { return nil }
            let value = rendered(source: source, typography: typography, tone: tone)
            appliedKey = key
            applyCount += 1
            return value
        }

        func cachedHeight(for width: CGFloat) -> CGFloat? {
            guard measuredWidth == width else { return nil }
            return measuredHeight
        }

        func cacheHeight(_ height: CGFloat, for width: CGFloat) {
            measuredWidth = width
            measuredHeight = height
        }

        private struct RenderedKey: Equatable {
            let source: String
            let typography: WorkspaceTypography
            let tone: AgentMarkdownTone
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NativeAgentMarkdownTextView {
        let textView = NativeAgentMarkdownTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // Keep the first and last code lines clear of the text view edge. Without
        // this native inset, the first glyph can look clipped while a response is
        // still streaming and the code block has not reached its final height.
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        update(textView, coordinator: context.coordinator)
        return textView
    }

    func updateNSView(_ textView: NativeAgentMarkdownTextView, context: Context) {
        update(textView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NativeAgentMarkdownTextView,
        context: Context
    ) -> CGSize? {
        let width = max(proposal.width ?? textView.bounds.width, 1)
        if let height = context.coordinator.cachedHeight(for: width) {
            return CGSize(width: width, height: height)
        }
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return nil }
        if abs(textView.frame.width - width) > 0.5 {
            // TextKit needs the proposed width to lay out wrapped lines. Update
            // only when the width actually changes so scrolling cannot create a
            // frame-measurement feedback loop.
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height)
            + textView.textContainerInset.height * 2
        let resolvedHeight = max(height, typography.pointSize + 2)
        context.coordinator.cacheHeight(resolvedHeight, for: width)
        return CGSize(width: width, height: resolvedHeight)
    }

    private func update(
        _ textView: NativeAgentMarkdownTextView,
        coordinator: Coordinator
    ) {
        textView.copyResponseSource = copyResponseSource
        guard let rendered = coordinator.renderedUpdate(
            source: source,
            typography: typography,
            tone: tone
        ) else { return }
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(rendered)
        if selection.location != NSNotFound,
           selection.length > 0,
           NSMaxRange(selection) <= rendered.length {
            textView.setSelectedRange(selection)
        }
        textView.invalidateIntrinsicContentSize()
        textView.needsLayout = true
        textView.superview?.needsLayout = true
    }
}

@MainActor
enum NativeAgentMarkdownRenderer {
    static func render(
        _ document: AgentMarkdownDocument,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            append(block, to: output, typography: typography, tone: tone, listDepth: 0)
            if index < document.blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    private static func append(
        _ block: AgentMarkdownBlock,
        to output: NSMutableAttributedString,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        listDepth: Int
    ) {
        switch block {
        case let .paragraph(runs):
            output.append(inline(runs, font: typography.nsFont(for: .body), tone: tone))
        case let .heading(level, runs):
            let style: NSFont.TextStyle = switch level {
            case 1: .title2
            case 2: .title3
            case 3: .headline
            default: .subheadline
            }
            let font = withTraits(typography.nsFont(for: style), [.boldFontMask])
            output.append(inline(runs, font: font, tone: tone))
        case let .codeBlock(language, code):
            if let language, !language.isEmpty {
                output.append(NSAttributedString(
                    string: language + "\n",
                    attributes: attributes(
                        font: .systemFont(ofSize: max(10, typography.pointSize - 2), weight: .medium),
                        color: .secondaryLabelColor
                    )
                ))
            }
            let style = paragraphStyle(spacing: 0)
            output.append(NSAttributedString(
                string: normalizedCode(code),
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: max(11, typography.pointSize - 1),
                        weight: .regular
                    ),
                    .foregroundColor: color(for: tone),
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                    .paragraphStyle: style,
                ]
            ))
        case let .blockQuote(blocks):
            for (index, child) in blocks.enumerated() {
                output.append(NSAttributedString(
                    string: "\u{2502} ",
                    attributes: attributes(
                        font: typography.nsFont(for: .body),
                        color: .tertiaryLabelColor
                    )
                ))
                append(child, to: output, typography: typography, tone: .secondary, listDepth: listDepth)
                if index < blocks.count - 1 { output.append(NSAttributedString(string: "\n")) }
            }
        case let .unorderedList(items):
            appendList(items, start: nil, to: output, typography: typography, tone: tone, depth: listDepth)
        case let .orderedList(start, items):
            appendList(items, start: start, to: output, typography: typography, tone: tone, depth: listDepth)
        case .thematicBreak:
            output.append(NSAttributedString(
                string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
                attributes: attributes(
                    font: typography.nsFont(for: .body),
                    color: .separatorColor
                )
            ))
        case let .table(headers, rows):
            let tableRows = headers.isEmpty ? rows : [headers] + rows
            for (rowIndex, row) in tableRows.enumerated() {
                for (cellIndex, cell) in row.enumerated() {
                    let font = rowIndex == 0 && !headers.isEmpty
                        ? withTraits(typography.nsFont(for: .callout), [.boldFontMask])
                        : typography.nsFont(for: .callout)
                    output.append(inline(cell, font: font, tone: tone))
                    if cellIndex < row.count - 1 { output.append(NSAttributedString(string: "\t")) }
                }
                if rowIndex < tableRows.count - 1 { output.append(NSAttributedString(string: "\n")) }
            }
        }
    }

    private static func normalizedCode(_ code: String) -> String {
        guard !code.isEmpty else { return code }
        var result = code
        // Markdown fences own the line break immediately inside the fence. A
        // streaming update can expose that delimiter newline as an empty first
        // line; remove only boundary blank lines and preserve code indentation
        // and blank lines within the block.
        if result.hasPrefix("\n") { result.removeFirst() }
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func appendList(
        _ items: [[AgentMarkdownBlock]],
        start: Int?,
        to output: NSMutableAttributedString,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        depth: Int
    ) {
        for (offset, item) in items.enumerated() {
            let prefix = start.map { "\($0 + offset). " } ?? "\u{2022} "
            output.append(NSAttributedString(
                string: String(repeating: "  ", count: depth) + prefix,
                attributes: attributes(
                    font: typography.nsFont(for: .body),
                    color: .secondaryLabelColor
                )
            ))
            for (blockIndex, block) in item.enumerated() {
                append(block, to: output, typography: typography, tone: tone, listDepth: depth + 1)
                if blockIndex < item.count - 1 { output.append(NSAttributedString(string: "\n")) }
            }
            if offset < items.count - 1 { output.append(NSAttributedString(string: "\n")) }
        }
    }

    private static func inline(
        _ runs: [AgentMarkdownRun],
        font baseFont: NSFont,
        tone: AgentMarkdownTone
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in runs {
            if let math = run.math,
               let attachment = mathAttachment(math, bodySize: baseFont.pointSize) {
                output.append(attachment)
                continue
            }
            var font = baseFont
            var traits: NSFontTraitMask = []
            if run.traits.contains(.strong) { traits.insert(.boldFontMask) }
            if run.traits.contains(.emphasis) { traits.insert(.italicFontMask) }
            if !traits.isEmpty { font = withTraits(font, traits) }
            if run.traits.contains(.code) {
                font = .monospacedSystemFont(ofSize: baseFont.pointSize * 0.93, weight: .regular)
            }
            var values = attributes(font: font, color: color(for: tone))
            if run.traits.contains(.strikethrough) {
                values[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.traits.contains(.code) {
                values[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.16)
            }
            if let destination = run.destination {
                values[.link] = destination
                values[.foregroundColor] = NSColor.controlAccentColor
            }
            output.append(NSAttributedString(string: run.text, attributes: values))
        }
        return output
    }

    private static func mathAttachment(_ math: AgentMath, bodySize: CGFloat) -> NSAttributedString? {
        let label = NativeMathLabel(frame: .zero)
        NativeMathMetrics.configure(label, for: math, bodySize: bodySize)
        let size = label.fittingSize
        guard label.error == nil, size.width > 0, size.height > 0 else { return nil }
        label.frame = NSRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()
        guard let bitmap = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: bitmap)
        let formulaImage = NSImage(size: size)
        formulaImage.addRepresentation(bitmap)
        let padding: CGFloat = math.boxed ? 5 : 0
        let renderedSize = NSSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let image = NSImage(size: renderedSize)
        image.lockFocus()
        formulaImage.draw(in: NSRect(x: padding, y: padding, width: size.width, height: size.height))
        if math.boxed {
            NSColor.labelColor.setStroke()
            let border = NSBezierPath(rect: NSRect(origin: .zero, size: renderedSize).insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        image.unlockFocus()
        let attachment = NSTextAttachment()
        attachment.image = image
        let formulaBaseline = min(
            max(label.displayList?.ascent ?? size.height * 0.8, 0),
            size.height
        )
        let baselineFromTop = padding + formulaBaseline
        attachment.bounds = NSRect(
            x: 0,
            y: baselineFromTop - renderedSize.height,
            width: renderedSize.width,
            height: renderedSize.height
        )
        let source = math.display
            ? "\\[\(math.sourceLatex)\\]"
            : "\\(\(math.sourceLatex)\\)"
        let rendered = NSMutableAttributedString(attachment: attachment)
        rendered.addAttribute(
            .kubecodeMathSource,
            value: source,
            range: NSRange(location: 0, length: rendered.length)
        )
        rendered.addAttribute(
            .kubecodeMathPointSize,
            value: bodySize,
            range: NSRange(location: 0, length: rendered.length)
        )
        if math.display {
            let style = paragraphStyle(spacing: 9)
            style.alignment = .center
            rendered.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: 0, length: rendered.length)
            )
        }
        return rendered
    }

    private static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(spacing: 9),
        ]
    }

    private static func paragraphStyle(
        spacing: CGFloat,
        headIndent: CGFloat = 0,
        tailIndent: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        style.headIndent = headIndent
        style.firstLineHeadIndent = headIndent
        style.tailIndent = tailIndent
        return style
    }

    private static func color(for tone: AgentMarkdownTone) -> NSColor {
        tone == .primary ? .labelColor : .secondaryLabelColor
    }

    private static func withTraits(_ font: NSFont, _ traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: traits)
    }
}
