import AppKit
import KubecodeMarkdown
import SwiftUI

enum AgentMarkdownTone: Equatable, Hashable {
    case primary
    case secondary
}

private extension NSAttributedString.Key {
    static let kubecodeMathSource = NSAttributedString.Key("dev.kubecode.math-source")
    static let kubecodeMathPointSize = NSAttributedString.Key("dev.kubecode.math-point-size")
    static let kubecodeAccessibilityReplacement = NSAttributedString.Key(
        "dev.kubecode.accessibility-replacement"
    )
}

final class NativeAgentMarkdownTextView: NSTextView {
    private var publishedAccessibilityValue: String?
    var copyResponseSource: String? {
        didSet { updateAccessibilityCustomActions() }
    }
    var linkOpener: ((URL) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func accessibilityValue() -> String? {
        publishedAccessibilityValue ?? super.accessibilityValue()
    }

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
            .kubecodeAccessibilityReplacement,
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

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url: URL?
        if let link = link as? URL {
            url = link
        } else if let link = link as? String {
            url = URL(string: link)
        } else {
            url = nil
        }
        guard let url, AgentMarkdownLinkPolicy.allows(url) else { return }
        if let linkOpener {
            linkOpener(url)
        } else {
            super.clicked(onLink: url, at: charIndex)
        }
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

    @discardableResult
    private func copyResponseToPasteboard() -> Bool {
        guard let copyResponseSource, !copyResponseSource.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyResponseSource, forType: .string)
        return true
    }

    @objc private func copyResponse(_ sender: Any?) {
        _ = copyResponseToPasteboard()
    }

    fileprivate func publishAccessibilityValue(from value: NSAttributedString) {
        let accessibleValue = NSMutableAttributedString(attributedString: value)
        var replacements: [(NSRange, String)] = []
        accessibleValue.enumerateAttribute(
            .kubecodeAccessibilityReplacement,
            in: NSRange(location: 0, length: accessibleValue.length)
        ) { replacement, range, _ in
            if let replacement = replacement as? String {
                replacements.append((range, replacement))
            }
        }
        for (range, replacement) in replacements.reversed() {
            accessibleValue.replaceCharacters(in: range, with: replacement)
        }
        publishedAccessibilityValue = accessibleValue.string
    }

    private func updateAccessibilityCustomActions() {
        guard copyResponseSource?.isEmpty == false else {
            setAccessibilityCustomActions([])
            return
        }
        let action = NSAccessibilityCustomAction(
            name: String(localized: "Copy Response"),
            handler: { [weak self] in self?.copyResponseToPasteboard() ?? false }
        )
        setAccessibilityCustomActions([action])
    }
}

struct NativeSelectableAgentMarkdownView: NSViewRepresentable {
    let source: String
    let typography: WorkspaceTypography
    let tone: AgentMarkdownTone
    let copyResponseSource: String?
    let isStreaming: Bool
    let resourceContext: MarkdownProjectResourceContext?
    let preparedCommit: AgentMarkdownRenderCommit?
    let renderStore: AgentMarkdownRenderStore?
    let renderIdentity: AgentMarkdownRenderIdentity?
    let onRenderHeight: ((AgentMarkdownRenderHeightCommit) -> Void)?

    init(
        source: String,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        copyResponseSource: String?,
        isStreaming: Bool = false,
        resourceContext: MarkdownProjectResourceContext? = nil,
        preparedCommit: AgentMarkdownRenderCommit? = nil,
        renderStore: AgentMarkdownRenderStore? = nil,
        renderIdentity: AgentMarkdownRenderIdentity? = nil,
        onRenderHeight: ((AgentMarkdownRenderHeightCommit) -> Void)? = nil
    ) {
        self.source = source
        self.typography = typography
        self.tone = tone
        self.copyResponseSource = copyResponseSource
        self.isStreaming = isStreaming
        self.resourceContext = resourceContext
        self.preparedCommit = preparedCommit
        self.renderStore = renderStore
        self.renderIdentity = renderIdentity
        self.onRenderHeight = onRenderHeight
    }

    @MainActor
    final class Coordinator {
        private var renderedKey: RenderedKey?
        private var renderedValue: NSAttributedString?
        private var legacyAppliedKey: RenderedKey?
        private var measuredWidth: CGFloat?
        private var measuredHeight: CGFloat?
        private var measuredSource: String?
        private var measuredResourceIdentity: String?
        private var publishedHeightIdentity: AgentMarkdownRenderIdentity?
        private var publishedHeightKey: AgentMarkdownRenderKey?
        private var publishedHeight: CGFloat?
        private(set) var renderCount = 0
        private(set) var applyCount = 0
        private(set) var preparedRenderCount = 0
        private(set) var preparedApplyCount = 0
        private(set) var latestPreparedCommit: AgentMarkdownRenderCommit?

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

        func prepareMeasurement(source: String, resourceIdentity: String?) {
            guard measuredSource != source || measuredResourceIdentity != resourceIdentity else { return }
            measuredSource = source
            measuredResourceIdentity = resourceIdentity
            measuredWidth = nil
            measuredHeight = nil
        }

        func receivePreparedCommit(
            _ commit: AgentMarkdownRenderCommit,
            resourceContext: MarkdownProjectResourceContext? = nil,
            isAuthoritative: Bool = false,
            to textView: NativeAgentMarkdownTextView
        ) {
            if let latestPreparedCommit,
               latestPreparedCommit.contentVersion > commit.contentVersion
                || (latestPreparedCommit.contentVersion == commit.contentVersion
                    && latestPreparedCommit.generation > commit.generation)
                || latestPreparedCommit === commit
            {
                return
            }
            preparedRenderCount += 1
            let commitToApply = isAuthoritative
                ? commit
                : latestPreparedCommit.map { commit.carryingStablePrefix(from: $0) } ?? commit
            applyPreparedCommit(commitToApply, to: textView)
        }

        func applyPreparedCommit(
            _ commit: AgentMarkdownRenderCommit,
            to textView: NativeAgentMarkdownTextView
        ) {
            latestPreparedCommit = commit
            let result = NativeMarkdownSuffixApplier.apply(commit, to: textView)
            textView.publishAccessibilityValue(from: commit.attributedValue)
            if result != .unchanged { preparedApplyCount += 1 }
            measuredSource = commit.source
            measuredWidth = nil
            measuredHeight = nil
            textView.invalidateIntrinsicContentSize()
        }

        func measurementCommit(forSource source: String) -> AgentMarkdownRenderCommit? {
            guard latestPreparedCommit?.source == source else { return nil }
            return latestPreparedCommit
        }

        func shouldPublishHeight(
            _ commit: AgentMarkdownRenderHeightCommit,
            identity: AgentMarkdownRenderIdentity
        ) -> Bool {
            guard publishedHeightIdentity != identity
                || publishedHeightKey != commit.key
                || publishedHeight != commit.height
            else {
                return false
            }
            publishedHeightIdentity = identity
            publishedHeightKey = commit.key
            publishedHeight = commit.height
            return true
        }

        func renderedUpdate(
            source: String,
            typography: WorkspaceTypography,
            tone: AgentMarkdownTone
        ) -> NSAttributedString? {
            let key = RenderedKey(source: source, typography: typography, tone: tone)
            guard legacyAppliedKey != key else { return nil }
            let value = rendered(source: source, typography: typography, tone: tone)
            legacyAppliedKey = key
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
            let resourceIdentity: String?

            init(
                source: String,
                typography: WorkspaceTypography,
                tone: AgentMarkdownTone,
                resourceIdentity: String? = nil
            ) {
                self.source = source
                self.typography = typography
                self.tone = tone
                self.resourceIdentity = resourceIdentity
            }
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
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
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
        context.coordinator.prepareMeasurement(
            source: source,
            resourceIdentity: resourceContext?.identity
        )
        guard context.coordinator.measurementCommit(forSource: source) != nil,
              let renderStore,
              let renderIdentity,
              let measured = renderStore.heightCommit(
                identity: renderIdentity,
                width: width,
                verticalInset: textView.textContainerInset.height
              )
        else {
            return nil
        }
        if context.coordinator.shouldPublishHeight(measured, identity: renderIdentity) {
            onRenderHeight?(measured)
        }
        return CGSize(width: measured.key.effectiveWidth, height: measured.height)
    }

    private func update(
        _ textView: NativeAgentMarkdownTextView,
        coordinator: Coordinator
    ) {
        textView.copyResponseSource = copyResponseSource
        guard let preparedCommit else { return }
        coordinator.receivePreparedCommit(
            preparedCommit,
            resourceContext: resourceContext,
            isAuthoritative: renderStore != nil,
            to: textView
        )
    }
}

enum NativeAgentMarkdownMeasurement {
    struct Result {
        let usedRect: NSRect
        let height: CGFloat
    }

    static func measure(
        rendered: NSAttributedString,
        width: CGFloat,
        minimumHeight: CGFloat,
        verticalInset: CGFloat
    ) -> Result {
        let textStorage = NSTextStorage(attributedString: rendered)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        let textContainer = NSTextContainer(size: NSSize(
            width: max(width, 1).rounded(.toNearestOrAwayFromZero),
            height: .greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return Result(
            usedRect: usedRect,
            height: max(ceil(usedRect.maxY) + verticalInset * 2, minimumHeight)
        )
    }

    static func height(
        for rendered: NSAttributedString,
        width: CGFloat,
        minimumHeight: CGFloat,
        verticalInset: CGFloat
    ) -> CGFloat {
        measure(
            rendered: rendered,
            width: width,
            minimumHeight: minimumHeight,
            verticalInset: verticalInset
        ).height
    }
}

@MainActor
enum NativeAgentMarkdownRenderer {
    static func render(
        _ document: AgentMarkdownDocument,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        images: [String: NSImage] = [:]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            output.append(render(
                block: block,
                typography: typography,
                tone: tone,
                images: images
            ))
            if index < document.blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    static func render(
        block: AgentMarkdownBlock,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        images: [String: NSImage] = [:]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        append(
            block,
            to: output,
            typography: typography,
            tone: tone,
            listDepth: 0,
            images: images
        )
        trimBoundaryLineBreaks(output)
        return NSAttributedString(attributedString: output)
    }

    private static func trimBoundaryLineBreaks(_ value: NSMutableAttributedString) {
        while value.length > 0, value.string.hasPrefix("\n") {
            value.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        while value.length > 0, value.string.hasSuffix("\n") {
            value.deleteCharacters(in: NSRange(location: value.length - 1, length: 1))
        }
    }

    private static func append(
        _ block: AgentMarkdownBlock,
        to output: NSMutableAttributedString,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        listDepth: Int,
        images: [String: NSImage]
    ) {
        switch block {
        case let .paragraph(runs):
            output.append(inline(runs, font: typography.nsFont(for: .body), tone: tone, images: images))
        case let .heading(level, runs):
            let style: NSFont.TextStyle = switch level {
            case 1: .title2
            case 2: .title3
            case 3: .headline
            default: .subheadline
            }
            let font = withTraits(typography.nsFont(for: style), [.boldFontMask])
            output.append(inline(runs, font: font, tone: tone, images: images))
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
            let normalized = normalizedCode(code)
            let highlighted = NSMutableAttributedString(attributedString: CodeSyntaxHighlighter.attributedString(
                normalized,
                languageIdentifier: language,
                font: .monospacedSystemFont(
                    ofSize: max(11, typography.pointSize - 1),
                    weight: .regular
                )
            ))
            if highlighted.length > 0 {
                highlighted.addAttribute(
                    .backgroundColor,
                    value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                    range: NSRange(location: 0, length: highlighted.length)
                )
            }
            output.append(highlighted)
        case let .blockQuote(blocks):
            for (index, child) in blocks.enumerated() {
                output.append(NSAttributedString(
                    string: "\u{2502} ",
                    attributes: attributes(
                        font: typography.nsFont(for: .body),
                        color: .tertiaryLabelColor
                    )
                ))
                append(
                    child,
                    to: output,
                    typography: typography,
                    tone: .secondary,
                    listDepth: listDepth,
                    images: images
                )
                if index < blocks.count - 1 { output.append(NSAttributedString(string: "\n")) }
            }
        case let .unorderedList(items):
            appendList(
                items,
                start: nil,
                to: output,
                typography: typography,
                tone: tone,
                depth: listDepth,
                images: images
            )
        case let .orderedList(start, items):
            appendList(
                items,
                start: start,
                to: output,
                typography: typography,
                tone: tone,
                depth: listDepth,
                images: images
            )
        case .thematicBreak:
            output.append(NSAttributedString(
                string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
                attributes: attributes(
                    font: typography.nsFont(for: .body),
                    color: .separatorColor
                )
            ))
        case let .table(alignments, headers, rows):
            appendTable(
                alignments: alignments,
                headers: headers,
                rows: rows,
                to: output,
                typography: typography,
                tone: tone,
                images: images
            )
        case let .rawHTML(value):
            output.append(NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: max(11, typography.pointSize - 1),
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.1),
                ]
            ))
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
        _ items: [AgentMarkdownListItem],
        start: Int?,
        to output: NSMutableAttributedString,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        depth: Int,
        images: [String: NSImage]
    ) {
        for (offset, item) in items.enumerated() {
            let prefix = switch item.checkbox {
            case .checked?: "☑ "
            case .unchecked?: "☐ "
            case nil: start.map { "\($0 + offset). " } ?? "\u{2022} "
            }
            output.append(NSAttributedString(
                string: String(repeating: "  ", count: depth) + prefix,
                attributes: attributes(
                    font: typography.nsFont(for: .body),
                    color: .secondaryLabelColor
                )
            ))
            for (blockIndex, block) in item.blocks.enumerated() {
                append(
                    block,
                    to: output,
                    typography: typography,
                    tone: tone,
                    listDepth: depth + 1,
                    images: images
                )
                if blockIndex < item.blocks.count - 1 { output.append(NSAttributedString(string: "\n")) }
            }
            if offset < items.count - 1 { output.append(NSAttributedString(string: "\n")) }
        }
    }

    private static func appendTable(
        alignments: [AgentMarkdownTableAlignment],
        headers: [[AgentMarkdownRun]],
        rows: [[[AgentMarkdownRun]]],
        to output: NSMutableAttributedString,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        images: [String: NSImage]
    ) {
        let tableRows = headers.isEmpty ? rows : [headers] + rows
        let columnCount = tableRows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        for (rowIndex, row) in tableRows.enumerated() {
            for columnIndex in 0..<columnCount {
                let cell = columnIndex < row.count ? row[columnIndex] : []
                let font = rowIndex == 0 && !headers.isEmpty
                    ? withTraits(typography.nsFont(for: .callout), [.boldFontMask])
                    : typography.nsFont(for: .callout)
                let value = NSMutableAttributedString(attributedString: inline(
                    cell,
                    font: font,
                    tone: tone,
                    images: images
                ))
                if value.length == 0 { value.append(NSAttributedString(string: " ")) }

                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(7, type: .absoluteValueType, for: .padding)
                if rowIndex == 0, !headers.isEmpty {
                    block.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.alignment = textAlignment(
                    columnIndex < alignments.count ? alignments[columnIndex] : .unspecified
                )
                value.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: value.length)
                )
                output.append(value)
                output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
            }
        }
        if output.string.hasSuffix("\n") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
    }

    private static func textAlignment(_ alignment: AgentMarkdownTableAlignment) -> NSTextAlignment {
        switch alignment {
        case .left, .unspecified: .left
        case .center: .center
        case .right: .right
        }
    }

    private static func inline(
        _ runs: [AgentMarkdownRun],
        font baseFont: NSFont,
        tone: AgentMarkdownTone,
        images: [String: NSImage]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in runs {
            if let image = run.image {
                if let source = image.source, let loaded = images[source] {
                    output.append(imageAttachment(loaded, source: image, font: baseFont))
                } else {
                    output.append(imagePlaceholder(image, font: baseFont, tone: tone))
                }
                continue
            }
            if let math = run.math {
                if let attachment = mathAttachment(math, bodySize: baseFont.pointSize) {
                    output.append(attachment)
                } else {
                    let delimiter = math.display
                        ? (#"\["#, #"\]"#)
                        : (#"\("#, #"\)"#)
                    output.append(NSAttributedString(
                        string: delimiter.0 + math.sourceLatex + delimiter.1,
                        attributes: [
                            .font: NSFont.monospacedSystemFont(
                                ofSize: baseFont.pointSize * 0.93,
                                weight: .regular
                            ),
                            .foregroundColor: color(for: tone),
                            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                        ]
                    ))
                }
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

    private static func imageAttachment(
        _ image: NSImage,
        source: AgentMarkdownImage,
        font: NSFont
    ) -> NSAttributedString {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return imagePlaceholder(source, font: font, tone: .secondary)
        }
        let scale = min(1, 640 / sourceSize.width, 480 / sourceSize.height)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: -3,
            width: floor(sourceSize.width * scale),
            height: floor(sourceSize.height * scale)
        )
        let rendered = NSMutableAttributedString(attachment: attachment)
        let label = source.alt.isEmpty ? String(localized: "Image") : source.alt
        rendered.addAttribute(
            .kubecodeAccessibilityReplacement,
            value: label,
            range: NSRange(location: 0, length: rendered.length)
        )
        return rendered
    }

    private static func imagePlaceholder(
        _ image: AgentMarkdownImage,
        font: NSFont,
        tone: AgentMarkdownTone
    ) -> NSAttributedString {
        let label = image.alt.isEmpty ? String(localized: "Image") : image.alt
        let symbol = NSTextAttachment()
        symbol.image = NSImage(
            systemSymbolName: "photo",
            accessibilityDescription: label
        )
        symbol.bounds = CGRect(x: 0, y: -2, width: font.pointSize + 2, height: font.pointSize + 2)
        let result = NSMutableAttributedString(attachment: symbol)
        result.addAttribute(
            .kubecodeAccessibilityReplacement,
            value: "",
            range: NSRange(location: 0, length: result.length)
        )
        result.append(NSAttributedString(
            string: " \(label)",
            attributes: attributes(font: font, color: color(for: tone))
        ))
        return result
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
            .kubecodeAccessibilityReplacement,
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
