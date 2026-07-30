import Foundation

public struct StreamingMarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case parsed(MarkdownBlock)
        case literal(String)
    }

    public let id: String
    public let sourceRange: MarkdownSourceRange?
    public let content: Content

    public init(
        id: String,
        sourceRange: MarkdownSourceRange?,
        content: Content
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.content = content
    }

    public var parsedBlock: MarkdownBlock? {
        guard case let .parsed(block) = content else { return nil }
        return block
    }

    public var literalSource: String? {
        guard case let .literal(source) = content else { return nil }
        return source
    }

    public var plainText: String {
        switch content {
        case let .parsed(block): block.plainText
        case let .literal(source): source
        }
    }

    fileprivate func isSemanticallyEqual(to other: Self) -> Bool {
        switch (content, other.content) {
        case let (.parsed(lhs), .parsed(rhs)):
            lhs.isRenderSemanticallyEqual(to: rhs)
        case let (.literal(lhs), .literal(rhs)):
            lhs == rhs
        case (.parsed, .literal), (.literal, .parsed):
            false
        }
    }
}

private extension MarkdownBlock {
    func isRenderSemanticallyEqual(to other: MarkdownBlock) -> Bool {
        switch (kind, other.kind) {
        case let (.paragraph(lhs), .paragraph(rhs)):
            lhs.isRenderSemanticallyEqual(to: rhs)
        case let (.heading(lhsLevel, lhs), .heading(rhsLevel, rhs)):
            lhsLevel == rhsLevel && lhs.isRenderSemanticallyEqual(to: rhs)
        case let (.codeBlock(lhsLanguage, lhsCode), .codeBlock(rhsLanguage, rhsCode)):
            lhsLanguage == rhsLanguage && lhsCode == rhsCode
        case let (.blockQuote(lhs), .blockQuote(rhs)):
            lhs.isRenderSemanticallyEqual(to: rhs)
        case let (.unorderedList(lhs), .unorderedList(rhs)):
            lhs.isRenderSemanticallyEqual(to: rhs)
        case let (.orderedList(lhsStart, lhs), .orderedList(rhsStart, rhs)):
            lhsStart == rhsStart && lhs.isRenderSemanticallyEqual(to: rhs)
        case (.thematicBreak, .thematicBreak):
            true
        case let (.table(lhs), .table(rhs)):
            lhs.isRenderSemanticallyEqual(to: rhs)
        case let (.rawHTML(lhs), .rawHTML(rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

private extension MarkdownInline {
    func isRenderSemanticallyEqual(to other: MarkdownInline) -> Bool {
        switch (kind, other.kind) {
        case let (.text(lhsValue, lhsTraits), .text(rhsValue, rhsTraits)):
            lhsValue == rhsValue && lhsTraits == rhsTraits
        case let (.code(lhs), .code(rhs)):
            lhs == rhs
        case let (.math(lhs), .math(rhs)):
            lhs == rhs
        case let (
            .link(lhsDestination, lhsTitle, lhsChildren),
            .link(rhsDestination, rhsTitle, rhsChildren)
        ):
            lhsDestination == rhsDestination
                && lhsTitle == rhsTitle
                && lhsChildren.isRenderSemanticallyEqual(to: rhsChildren)
        case let (
            .image(lhsSource, lhsTitle, lhsAlt),
            .image(rhsSource, rhsTitle, rhsAlt)
        ):
            lhsSource == rhsSource && lhsTitle == rhsTitle && lhsAlt == rhsAlt
        case (.softBreak, .softBreak), (.lineBreak, .lineBreak):
            true
        case let (.rawHTML(lhs), .rawHTML(rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

private extension MarkdownListItem {
    func isRenderSemanticallyEqual(to other: MarkdownListItem) -> Bool {
        checkbox == other.checkbox && blocks.isRenderSemanticallyEqual(to: other.blocks)
    }
}

private extension MarkdownTable {
    func isRenderSemanticallyEqual(to other: MarkdownTable) -> Bool {
        columnAlignments == other.columnAlignments
            && headers.isRenderSemanticallyEqual(to: other.headers)
            && rows.isRenderSemanticallyEqual(to: other.rows)
    }
}

private extension Array where Element == MarkdownBlock {
    func isRenderSemanticallyEqual(to other: Self) -> Bool {
        count == other.count && zip(self, other).allSatisfy { lhs, rhs in
            lhs.isRenderSemanticallyEqual(to: rhs)
        }
    }
}

private extension Array where Element == MarkdownInline {
    func isRenderSemanticallyEqual(to other: Self) -> Bool {
        count == other.count && zip(self, other).allSatisfy { lhs, rhs in
            lhs.isRenderSemanticallyEqual(to: rhs)
        }
    }
}

private extension Array where Element == MarkdownListItem {
    func isRenderSemanticallyEqual(to other: Self) -> Bool {
        count == other.count && zip(self, other).allSatisfy { lhs, rhs in
            lhs.isRenderSemanticallyEqual(to: rhs)
        }
    }
}

private extension Array where Element == [MarkdownInline] {
    func isRenderSemanticallyEqual(to other: Self) -> Bool {
        count == other.count && zip(self, other).allSatisfy { lhs, rhs in
            lhs.isRenderSemanticallyEqual(to: rhs)
        }
    }
}

private extension Array where Element == [[MarkdownInline]] {
    func isRenderSemanticallyEqual(to other: Self) -> Bool {
        count == other.count && zip(self, other).allSatisfy { lhs, rhs in
            lhs.isRenderSemanticallyEqual(to: rhs)
        }
    }
}

public struct StreamingMarkdownDocument: Equatable, Sendable {
    public let source: String
    public let blocks: [StreamingMarkdownBlock]
    public let stablePrefixCount: Int

    public init(
        source: String,
        previous: StreamingMarkdownDocument? = nil
    ) {
        let parsed = MarkdownParser.parse(source)
        let candidates = Self.renderBlocks(source: source, parsed: parsed)
        let stablePrefixCount = Self.stablePrefixCount(
            previous: previous,
            source: source,
            candidates: candidates
        )

        self.source = source
        self.stablePrefixCount = stablePrefixCount
        if let previous, stablePrefixCount > 0 {
            self.blocks = Array(previous.blocks.prefix(stablePrefixCount))
                + candidates.dropFirst(stablePrefixCount)
        } else {
            self.blocks = candidates
        }
    }

    public var stablePrefix: [StreamingMarkdownBlock] {
        Array(blocks.prefix(stablePrefixCount))
    }

    public var mutableTail: [StreamingMarkdownBlock] {
        Array(blocks.dropFirst(stablePrefixCount))
    }

    private static func stablePrefixCount(
        previous: StreamingMarkdownDocument?,
        source: String,
        candidates: [StreamingMarkdownBlock]
    ) -> Int {
        guard let previous,
              source != previous.source,
              source.hasPrefix(previous.source)
        else { return 0 }

        let limit = min(previous.blocks.count, candidates.count)
        var count = 0
        while count < limit {
            let old = previous.blocks[count]
            let new = candidates[count]
            guard old.id == new.id, old.isSemanticallyEqual(to: new) else { break }
            count += 1
        }
        return count
    }

    private static func renderBlocks(
        source: String,
        parsed: KubecodeMarkdownDocument
    ) -> [StreamingMarkdownBlock] {
        if let openingFence = unmatchedFence(in: source),
           let affectedIndex = parsed.blocks.firstIndex(where: { block in
                guard let range = block.sourceRange else { return false }
                return range.end.line >= openingFence.line
           }),
           parsed.blocks[affectedIndex].sourceRange?.start.line == openingFence.line
        {
            let prefix = parsed.blocks.prefix(affectedIndex).map(renderBlock)
            let tail = String(source[openingFence.sourceIndex...])
            return prefix + [StreamingMarkdownBlock(
                id: parsed.blocks[affectedIndex].id,
                sourceRange: .init(
                    start: .init(line: openingFence.line, column: 1),
                    end: endPosition(in: source)
                ),
                content: .literal(tail)
            )]
        }

        if parsed.blocks.isEmpty, source.contains(where: { !$0.isWhitespace }) {
            return [StreamingMarkdownBlock(
                id: "b0",
                sourceRange: .init(
                    start: .init(line: 1, column: 1),
                    end: endPosition(in: source)
                ),
                content: .literal(source)
            )]
        }

        return parsed.blocks.map(renderBlock)
    }

    private static func renderBlock(_ block: MarkdownBlock) -> StreamingMarkdownBlock {
        StreamingMarkdownBlock(
            id: block.id,
            sourceRange: block.sourceRange,
            content: .parsed(block)
        )
    }

    private struct OpeningFence {
        let marker: Character
        let length: Int
        let line: Int
        let sourceIndex: String.Index
    }

    private struct SourceLine {
        let number: Int
        let sourceIndex: String.Index
        let content: Substring
    }

    private static func unmatchedFence(in source: String) -> OpeningFence? {
        var opening: OpeningFence?
        for line in sourceLines(source) {
            if let current = opening {
                if isClosingFence(line.content, for: current) {
                    opening = nil
                }
            } else if let marker = openingFenceMarker(in: line.content) {
                opening = OpeningFence(
                    marker: marker.marker,
                    length: marker.length,
                    line: line.number,
                    sourceIndex: line.sourceIndex
                )
            }
        }
        return opening
    }

    private static func openingFenceMarker(
        in line: Substring
    ) -> (marker: Character, length: Int)? {
        guard let markerStart = markerStart(in: line), markerStart.leadingSpaces <= 3 else {
            return nil
        }
        let marker = line[markerStart.index]
        guard marker == "`" || marker == "~" else { return nil }
        let run = markerRun(in: line, from: markerStart.index, marker: marker)
        guard run.length >= 3 else { return nil }
        if marker == "`", line[run.endIndex...].contains("`") { return nil }
        return (marker, run.length)
    }

    private static func isClosingFence(
        _ line: Substring,
        for opening: OpeningFence
    ) -> Bool {
        guard let markerStart = markerStart(in: line), markerStart.leadingSpaces <= 3,
              line[markerStart.index] == opening.marker
        else { return false }
        let run = markerRun(
            in: line,
            from: markerStart.index,
            marker: opening.marker
        )
        guard run.length >= opening.length else { return false }
        return line[run.endIndex...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func markerStart(
        in line: Substring
    ) -> (index: Substring.Index, leadingSpaces: Int)? {
        var index = line.startIndex
        var spaces = 0
        while index < line.endIndex, line[index] == " " {
            spaces += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        return (index, spaces)
    }

    private static func markerRun(
        in line: Substring,
        from start: Substring.Index,
        marker: Character
    ) -> (length: Int, endIndex: Substring.Index) {
        var index = start
        var length = 0
        while index < line.endIndex, line[index] == marker {
            length += 1
            index = line.index(after: index)
        }
        return (length, index)
    }

    private static func sourceLines(_ source: String) -> [SourceLine] {
        var result: [SourceLine] = []
        var lineNumber = 1
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let newline = source[lineStart...].firstIndex(where: \.isNewline)
            let lineEnd = newline ?? source.endIndex
            result.append(SourceLine(
                number: lineNumber,
                sourceIndex: lineStart,
                content: source[lineStart..<lineEnd]
            ))
            guard let newline else { break }
            lineStart = source.index(after: newline)
            lineNumber += 1
        }
        return result
    }

    private static func endPosition(in source: String) -> MarkdownSourcePosition {
        var line = 1
        var column = 1
        for character in source {
            if character.isNewline {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return .init(line: line, column: column)
    }
}
