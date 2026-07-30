import SwiftUI
import SwiftMath
import KubecodeMarkdown

#if os(macOS)
import AppKit

struct AgentMarkdownView: View {
    @Environment(\.workspaceTypography) private var typography
    @Environment(\.markdownProjectResourceContext) private var resourceContext
    private let source: String
    private let tone: AgentMarkdownTone
    private let copyResponseSource: String?
    private let isStreaming: Bool
    @State private var renderSession = AgentMarkdownRenderSession()

    init(
        source: String,
        tone: AgentMarkdownTone = .primary,
        copyResponseSource: String? = nil,
        isStreaming: Bool = false
    ) {
        self.source = source
        self.tone = tone
        self.copyResponseSource = copyResponseSource
        self.isStreaming = isStreaming
    }

    var body: some View {
        let input = AgentMarkdownRenderInput(
            source: source,
            typography: typography,
            tone: tone,
            resourceIdentity: resourceContext?.identity,
            isStreaming: isStreaming
        )
        NativeSelectableAgentMarkdownView(
            source: source,
            typography: typography,
            tone: tone,
            copyResponseSource: copyResponseSource,
            isStreaming: isStreaming,
            resourceContext: resourceContext,
            preparedCommit: renderSession.latestCommit
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { submit(input) }
        .onChange(of: input) { _, value in submit(value) }
    }

    private func submit(_ input: AgentMarkdownRenderInput) {
        _ = renderSession.submit(
            source: input.source,
            typography: input.typography,
            tone: input.tone,
            resourceIdentity: input.resourceIdentity
        )
    }
}

private struct AgentMarkdownRenderInput: Equatable {
    let source: String
    let typography: WorkspaceTypography
    let tone: AgentMarkdownTone
    let resourceIdentity: String?
    let isStreaming: Bool
}

private struct MarkdownProjectResourceContextKey: EnvironmentKey {
    static let defaultValue: MarkdownProjectResourceContext? = nil
}

extension EnvironmentValues {
    var markdownProjectResourceContext: MarkdownProjectResourceContext? {
        get { self[MarkdownProjectResourceContextKey.self] }
        set { self[MarkdownProjectResourceContextKey.self] = newValue }
    }
}

private struct AgentMarkdownBlocksView: View {
    let blocks: [AgentMarkdownBlock]
    let foregroundStyle: HierarchicalShapeStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                AgentMarkdownBlockView(
                    block: block,
                    foregroundStyle: foregroundStyle
                )
            }
        }
    }
}

private struct AgentMarkdownBlockView: View {
    @Environment(\.workspaceTypography) private var typography
    let block: AgentMarkdownBlock
    let foregroundStyle: HierarchicalShapeStyle

    @ViewBuilder
    var body: some View {
        switch block {
        case let .paragraph(runs):
            AgentMarkdownParagraphView(runs: runs)
                .foregroundStyle(foregroundStyle)
        case let .heading(level, runs):
            AgentMarkdownInlineView(runs: runs)
                .font(headingFont(level))
                .foregroundStyle(foregroundStyle)
                .padding(.top, level <= 2 ? 4 : 1)
        case let .codeBlock(language, code):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                }
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(10)
                }
                .frame(height: codeBlockHeight(code))
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
            }
        case let .blockQuote(blocks):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                AgentMarkdownBlocksView(
                    blocks: blocks,
                    foregroundStyle: .secondary
                )
            }
            .padding(.vertical, 2)
        case let .unorderedList(items):
            listView(items: items, start: nil)
        case let .orderedList(start, items):
            listView(items: items, start: start)
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        case let .table(_, headers, rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    if !headers.isEmpty {
                        tableRow(headers, isHeader: true)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        tableRow(row, isHeader: false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.separator.opacity(0.55), lineWidth: 0.5)
                }
            }
        case let .rawHTML(value):
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: typography.swiftUIFont(for: .title2).weight(.semibold)
        case 2: typography.swiftUIFont(for: .title3).weight(.semibold)
        case 3: typography.swiftUIFont(for: .headline)
        default: typography.swiftUIFont(for: .subheadline).weight(.semibold)
        }
    }

    private func codeBlockHeight(_ code: String) -> CGFloat {
        let lineCount = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(max(CGFloat(lineCount) * 18 + 20, 40), 360)
    }

    private func listView(
        items: [AgentMarkdownListItem],
        start: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: listMarker(item.checkbox, start: start, offset: offset))
                        .font(typography.swiftUIFont(for: .body))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    AgentMarkdownBlocksView(
                        blocks: item.blocks,
                        foregroundStyle: foregroundStyle
                    )
                }
            }
        }
    }

    private func listMarker(_ checkbox: MarkdownCheckbox?, start: Int?, offset: Int) -> String {
        switch checkbox {
        case .checked?: "☑"
        case .unchecked?: "☐"
        case nil: start.map { "\($0 + offset)." } ?? "•"
        }
    }

    @ViewBuilder
    private func tableRow(
        _ cells: [[AgentMarkdownRun]],
        isHeader: Bool
    ) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                AgentMarkdownInlineView(runs: cell)
                    .font(typography.swiftUIFont(for: .callout).weight(isHeader ? .semibold : .regular))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(minWidth: 80, maxWidth: 280, alignment: .leading)
                    .background(isHeader ? Color.primary.opacity(0.055) : Color.clear)
                    .overlay(alignment: .trailing) { Divider() }
                    .overlay(alignment: .bottom) { Divider() }
            }
        }
    }
}

private struct AgentMarkdownParagraphView: View {
    let runs: [AgentMarkdownRun]

    var body: some View {
        let groups = paragraphGroups
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case let .inline(inlineRuns):
                    AgentMarkdownInlineView(runs: inlineRuns)
                case let .displayMath(math):
                    HStack {
                        Spacer(minLength: 0)
                        NativeMathView(math: math)
                            .fixedSize()
                            .padding(math.boxed ? 5 : 0)
                            .overlay {
                                if math.boxed {
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(.primary, lineWidth: 0.75)
                                }
                            }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var paragraphGroups: [ParagraphGroup] {
        guard runs.contains(where: { $0.math?.display == true }) else {
            return [.inline(runs)]
        }

        var groups: [ParagraphGroup] = []
        var inline: [AgentMarkdownRun] = []
        for run in runs {
            if let math = run.math, math.display {
                if inline.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    groups.append(.inline(inline))
                }
                inline.removeAll(keepingCapacity: true)
                groups.append(.displayMath(math))
            } else {
                inline.append(run)
            }
        }
        if inline.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            groups.append(.inline(inline))
        }
        return groups
    }

    private enum ParagraphGroup {
        case inline([AgentMarkdownRun])
        case displayMath(AgentMath)
    }
}

private struct AgentMarkdownInlineView: View {
    @Environment(\.workspaceTypography) private var typography
    let runs: [AgentMarkdownRun]

    var body: some View {
        if runs.contains(where: { $0.math != nil }) {
            MarkdownFlowLayout(rowSpacing: 3) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case let .text(run):
                        Text(attributed(run))
                    case let .math(math):
                        NativeMathView(math: math)
                            .fixedSize()
                            .layoutValue(
                                key: MathFirstBaselineKey.self,
                                value: NativeMathMetrics.firstBaselineOffset(
                                    for: math,
                                    bodySize: typography.pointSize
                                )
                            )
                            .padding(math.boxed ? 4 : 0)
                            .overlay {
                                if math.boxed {
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(.primary, lineWidth: 0.75)
                                }
                            }
                    }
                }
            }
        } else {
            Text(attributed(runs))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pieces: [InlinePiece] {
        runs.flatMap { run -> [InlinePiece] in
            if let math = run.math { return [.math(math)] }
            return Self.wordPieces(for: run).map(InlinePiece.text)
        }
    }

    private static func wordPieces(for run: AgentMarkdownRun) -> [AgentMarkdownRun] {
        guard run.text.contains(where: \.isWhitespace) else { return [run] }
        var result: [AgentMarkdownRun] = []
        var token = ""
        for character in run.text {
            if !character.isWhitespace, token.last?.isWhitespace == true {
                result.append(.init(
                    text: token,
                    traits: run.traits,
                    destination: run.destination
                ))
                token.removeAll(keepingCapacity: true)
            }
            token.append(character.isNewline ? " " : character)
        }
        if !token.isEmpty {
            result.append(.init(
                text: token,
                traits: run.traits,
                destination: run.destination
            ))
        }
        return result
    }

    private func attributed(_ runs: [AgentMarkdownRun]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            result.append(attributed(run))
        }
    }

    private func attributed(_ run: AgentMarkdownRun) -> AttributedString {
        var value = AttributedString(run.text)
        var intent: InlinePresentationIntent = []
        if run.traits.contains(.strong) { intent.insert(.stronglyEmphasized) }
        if run.traits.contains(.emphasis) { intent.insert(.emphasized) }
        if run.traits.contains(.strikethrough) { intent.insert(.strikethrough) }
        if run.traits.contains(.code) { intent.insert(.code) }
        if !intent.isEmpty { value.inlinePresentationIntent = intent }
        if let destination = run.destination { value.link = destination }
        return value
    }

    private enum InlinePiece {
        case text(AgentMarkdownRun)
        case math(AgentMath)
    }
}

struct MarkdownFlowLayout: Layout {
    let rowSpacing: CGFloat

    struct ItemMetrics: Equatable {
        let size: CGSize
        let firstTextBaseline: CGFloat
    }

    struct Geometry: Equatable {
        let size: CGSize
        let positions: [CGPoint]
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for (index, point) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> Geometry {
        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        let items = subviews.map { subview in
            var dimensions = subview.dimensions(in: .unspecified)
            if dimensions.width > maximumWidth {
                dimensions = subview.dimensions(in: .init(width: maximumWidth, height: nil))
            }
            return ItemMetrics(
                size: CGSize(width: dimensions.width, height: dimensions.height),
                firstTextBaseline: subview[MathFirstBaselineKey.self]
                    ?? dimensions[.firstTextBaseline]
            )
        }
        let geometry = Self.geometry(
            for: items,
            maximumWidth: maximumWidth,
            rowSpacing: rowSpacing
        )
        return Geometry(
            size: CGSize(width: proposal.width ?? geometry.size.width, height: geometry.size.height),
            positions: geometry.positions
        )
    }

    static func geometry(
        for items: [ItemMetrics],
        maximumWidth: CGFloat,
        rowSpacing: CGFloat
    ) -> Geometry {
        guard !items.isEmpty else { return Geometry(size: .zero, positions: []) }

        var positions = Array(repeating: CGPoint.zero, count: items.count)
        var rowIndices: [Int] = []
        var rowX: [CGFloat] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0

        func baseline(for item: ItemMetrics) -> CGFloat {
            min(max(item.firstTextBaseline, 0), item.size.height)
        }

        func placeRow() -> CGFloat {
            guard !rowIndices.isEmpty else { return 0 }
            let rowBaseline = rowIndices.map { baseline(for: items[$0]) }.max() ?? 0
            let rowDescent = rowIndices.map {
                items[$0].size.height - baseline(for: items[$0])
            }.max() ?? 0
            for (offset, index) in rowIndices.enumerated() {
                positions[index] = CGPoint(
                    x: rowX[offset],
                    y: y + rowBaseline - baseline(for: items[index])
                )
            }
            return rowBaseline + rowDescent
        }

        for index in items.indices {
            let item = items[index]
            if x > 0, x + item.size.width > maximumWidth {
                y += placeRow() + rowSpacing
                rowIndices.removeAll(keepingCapacity: true)
                rowX.removeAll(keepingCapacity: true)
                x = 0
            }
            rowIndices.append(index)
            rowX.append(x)
            x += item.size.width
            usedWidth = max(usedWidth, x)
        }
        let finalRowHeight = placeRow()

        return Geometry(
            size: CGSize(width: usedWidth, height: y + finalRowHeight),
            positions: positions
        )
    }
}

private struct MathFirstBaselineKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

typealias NativeMathLabel = MTMathUILabel

final class NativeMathContainer: NSView {
    let label = NativeMathLabel(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize { label.fittingSize }
    override var intrinsicContentSize: NSSize { label.fittingSize }

    override var firstBaselineOffsetFromTop: CGFloat {
        label.layoutSubtreeIfNeeded()
        return label.displayList?.ascent ?? label.fittingSize.height
    }

    override func layout() {
        label.frame = bounds
        label.layoutSubtreeIfNeeded()
        super.layout()
    }
}

@MainActor
enum NativeMathMetrics {
    static func firstBaselineOffset(for math: AgentMath, bodySize: CGFloat) -> CGFloat {
        let label = NativeMathLabel(frame: .zero)
        configure(label, for: math, bodySize: bodySize)
        let size = label.fittingSize
        label.frame = CGRect(origin: .zero, size: size)
        label.needsLayout = true
        label.layoutSubtreeIfNeeded()
        return min(max(label.displayList?.ascent ?? size.height * 0.8, 0), size.height)
    }

    static func configure(_ label: NativeMathLabel, for math: AgentMath, bodySize: CGFloat) {
        let size = math.display ? bodySize * 1.25 : bodySize
        label.font = MTFontManager().asanaFont(withSize: size)
        label.fontSize = size
        label.labelMode = math.display ? .display : .text
        label.textAlignment = math.display ? .center : .left
        label.textColor = NSColor.labelColor
        label.latex = math.latex
    }
}

private struct NativeMathView: NSViewRepresentable {
    @Environment(\.workspaceTypography) private var typography
    let math: AgentMath

    func makeNSView(context: Context) -> NativeMathContainer {
        let container = NativeMathContainer(frame: .zero)
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .vertical)
        container.label.displayErrorInline = true
        return container
    }

    func updateNSView(_ container: NativeMathContainer, context: Context) {
        let label = container.label
        NativeMathMetrics.configure(label, for: math, bodySize: typography.pointSize)
        label.invalidateIntrinsicContentSize()
        container.invalidateIntrinsicContentSize()
        container.needsLayout = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeMathContainer,
        context: Context
    ) -> CGSize? {
        nsView.fittingSize
    }
}
#endif
