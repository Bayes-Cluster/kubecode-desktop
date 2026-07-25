import Foundation

struct AgentMath: Equatable, Sendable {
    let latex: String
    let sourceLatex: String
    let display: Bool
    let boxed: Bool

    init(
        latex: String,
        sourceLatex: String? = nil,
        display: Bool,
        boxed: Bool = false
    ) {
        self.latex = latex
        self.sourceLatex = sourceLatex ?? latex
        self.display = display
        self.boxed = boxed
    }
}

struct AgentMarkdownTraits: OptionSet, Equatable, Hashable, Sendable {
    let rawValue: Int

    static let strong = Self(rawValue: 1 << 0)
    static let emphasis = Self(rawValue: 1 << 1)
    static let strikethrough = Self(rawValue: 1 << 2)
    static let code = Self(rawValue: 1 << 3)
}

struct AgentMarkdownRun: Equatable, Sendable {
    let text: String
    let traits: AgentMarkdownTraits
    let destination: URL?
    let math: AgentMath?

    init(
        text: String,
        traits: AgentMarkdownTraits = [],
        destination: URL? = nil,
        math: AgentMath? = nil
    ) {
        self.text = text
        self.traits = traits
        self.destination = destination
        self.math = math
    }
}

indirect enum AgentMarkdownBlock: Equatable, Sendable {
    case paragraph([AgentMarkdownRun])
    case heading(level: Int, [AgentMarkdownRun])
    case codeBlock(language: String?, code: String)
    case blockQuote([AgentMarkdownBlock])
    case unorderedList(items: [[AgentMarkdownBlock]])
    case orderedList(start: Int, items: [[AgentMarkdownBlock]])
    case thematicBreak
    case table(headers: [[AgentMarkdownRun]], rows: [[[AgentMarkdownRun]]])
}

struct AgentMarkdownDocument: Equatable, Sendable {
    let blocks: [AgentMarkdownBlock]

    init(source: String) {
        guard !source.isEmpty else {
            blocks = []
            return
        }

        let prepared = MathDelimiterParser.prepare(source)
        do {
            let attributed = try AttributedString(
                markdown: prepared.markdown,
                options: .init(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
            blocks = Self.project(
                attributed,
                fallback: source,
                mathPlaceholders: prepared.mathPlaceholders
            )
        } catch {
            blocks = [.paragraph(MathDelimiterParser.runs(in: source))]
        }
    }

    var inlineMath: [AgentMath] {
        blocks.flatMap(\.inlineMath)
    }

    var inlineRuns: [AgentMarkdownRun] {
        blocks.flatMap(\.inlineRuns)
    }

    var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    private static func project(
        _ attributed: AttributedString,
        fallback: String,
        mathPlaceholders: [String: AgentMath]
    ) -> [AgentMarkdownBlock] {
        var records: [BlockRecord] = []

        for run in attributed.runs {
            let value = String(attributed[run.range].characters)
            let context = BlockContext(intent: run.presentationIntent)
            let projectedRuns = MathDelimiterParser.runs(
                in: value,
                traits: traits(for: run.inlinePresentationIntent),
                destination: safeDestination(run.link),
                mathPlaceholders: mathPlaceholders
            )

            if let lastIndex = records.indices.last,
               records[lastIndex].context.groupKey == context.groupKey {
                records[lastIndex].append(
                    text: value,
                    runs: projectedRuns,
                    context: context
                )
            } else {
                records.append(BlockRecord(
                    context: context,
                    text: value,
                    runs: projectedRuns
                ))
            }
        }

        if records.isEmpty {
            return fallback.isEmpty ? [] : [.paragraph(MathDelimiterParser.runs(in: fallback))]
        }

        return foldContainers(records.map(\.blockRecord))
    }

    private static func traits(
        for intent: InlinePresentationIntent?
    ) -> AgentMarkdownTraits {
        guard let intent else { return [] }
        var result: AgentMarkdownTraits = []
        if intent.contains(.stronglyEmphasized) { result.insert(.strong) }
        if intent.contains(.emphasized) { result.insert(.emphasis) }
        if intent.contains(.strikethrough) { result.insert(.strikethrough) }
        if intent.contains(.code) { result.insert(.code) }
        return result
    }

    private static func safeDestination(_ destination: URL?) -> URL? {
        guard let destination,
              let scheme = destination.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return destination
    }

    private static func foldContainers(_ records: [ProjectedRecord]) -> [AgentMarkdownBlock] {
        var result: [AgentMarkdownBlock] = []
        var index = 0

        while index < records.count {
            let record = records[index]

            if let list = record.context.list {
                var items: [[AgentMarkdownBlock]] = []
                var next = index
                while next < records.count, records[next].context.list?.id == list.id {
                    items.append([records[next].block])
                    next += 1
                }
                switch list.kind {
                case .unordered:
                    result.append(.unorderedList(items: items))
                case let .ordered(start):
                    result.append(.orderedList(start: start, items: items))
                }
                index = next
                continue
            }

            if let quoteID = record.context.quoteID {
                var quoted: [AgentMarkdownBlock] = []
                var next = index
                while next < records.count, records[next].context.quoteID == quoteID {
                    quoted.append(records[next].block)
                    next += 1
                }
                result.append(.blockQuote(quoted))
                index = next
                continue
            }

            result.append(record.block)
            index += 1
        }

        return result
    }
}

private struct ProjectedRecord {
    let context: BlockContext
    let block: AgentMarkdownBlock
}

private struct BlockRecord {
    var context: BlockContext
    var text: String
    var runs: [AgentMarkdownRun]
    var tableCells: [TableCellKey: [AgentMarkdownRun]] = [:]

    init(context: BlockContext, text: String, runs: [AgentMarkdownRun]) {
        self.context = context
        self.text = text
        self.runs = runs
        if let cell = context.tableCell {
            tableCells[cell] = runs
        }
    }

    mutating func append(
        text newText: String,
        runs newRuns: [AgentMarkdownRun],
        context newContext: BlockContext
    ) {
        text += newText
        runs += newRuns
        if let cell = newContext.tableCell {
            tableCells[cell, default: []] += newRuns
        }
    }

    var blockRecord: ProjectedRecord {
        let block: AgentMarkdownBlock
        switch context.leaf {
        case let .heading(level):
            block = .heading(level: level, runs)
        case let .code(language):
            block = .codeBlock(language: language, code: text)
        case .thematicBreak:
            block = .thematicBreak
        case .table:
            let headerColumns = tableCells.keys
                .filter { $0.row == -1 }
                .map(\.column)
                .sorted()
            let headers = headerColumns.map { tableCells[.init(row: -1, column: $0)] ?? [] }
            let rowIndices = Set(tableCells.keys.filter { $0.row >= 0 }.map(\.row)).sorted()
            let rows = rowIndices.map { row in
                let columns = tableCells.keys
                    .filter { $0.row == row }
                    .map(\.column)
                    .sorted()
                return columns.map { tableCells[.init(row: row, column: $0)] ?? [] }
            }
            block = .table(headers: headers, rows: rows)
        case .paragraph:
            block = .paragraph(runs)
        }
        return ProjectedRecord(context: context, block: block)
    }
}

private struct TableCellKey: Hashable {
    let row: Int
    let column: Int
}

private struct BlockContext {
    enum Leaf: Equatable {
        case paragraph
        case heading(Int)
        case code(String?)
        case thematicBreak
        case table
    }

    struct ListContext: Equatable {
        enum Kind: Equatable {
            case unordered
            case ordered(start: Int)
        }

        let id: Int
        let kind: Kind
    }

    let leaf: Leaf
    let leafID: Int
    let list: ListContext?
    let quoteID: Int?
    let tableCell: TableCellKey?

    var groupKey: String {
        if case .table = leaf { return "table:\(leafID)" }
        return "leaf:\(leafID)"
    }

    init(intent: PresentationIntent?) {
        var resolvedLeaf: Leaf = .paragraph
        var resolvedLeafID = 0
        var resolvedList: ListContext?
        var resolvedQuoteID: Int?
        var tableID: Int?
        var tableRow: Int?
        var tableColumn: Int?

        for component in intent?.components ?? [] {
            switch component.kind {
            case .paragraph:
                resolvedLeaf = .paragraph
                resolvedLeafID = component.identity
            case let .header(level):
                resolvedLeaf = .heading(level)
                resolvedLeafID = component.identity
            case let .codeBlock(language):
                resolvedLeaf = .code(language)
                resolvedLeafID = component.identity
            case .thematicBreak:
                resolvedLeaf = .thematicBreak
                resolvedLeafID = component.identity
            case .unorderedList:
                resolvedList = .init(id: component.identity, kind: .unordered)
            case .orderedList:
                resolvedList = .init(id: component.identity, kind: .ordered(start: 1))
            case .blockQuote:
                resolvedQuoteID = component.identity
            case .table:
                tableID = component.identity
            case .tableHeaderRow:
                tableRow = -1
            case let .tableRow(row):
                tableRow = row
            case let .tableCell(column):
                tableColumn = column
            default:
                break
            }
        }

        if let tableID {
            resolvedLeaf = .table
            resolvedLeafID = tableID
        }

        leaf = resolvedLeaf
        leafID = resolvedLeafID
        list = resolvedList
        quoteID = resolvedQuoteID
        if let tableRow, let tableColumn {
            tableCell = .init(row: tableRow, column: tableColumn)
        } else {
            tableCell = nil
        }
    }
}

private enum MathDelimiterParser {
    struct PreparedMarkdown {
        let markdown: String
        let mathPlaceholders: [String: AgentMath]
    }

    static func runs(
        in value: String,
        traits: AgentMarkdownTraits = [],
        destination: URL? = nil,
        mathPlaceholders: [String: AgentMath] = [:]
    ) -> [AgentMarkdownRun] {
        guard !mathPlaceholders.isEmpty, !traits.contains(.code) else {
            return rawRuns(in: value, traits: traits, destination: destination)
        }

        var output: [AgentMarkdownRun] = []
        var index = value.startIndex
        while index < value.endIndex {
            let matches = mathPlaceholders.compactMap { token, math -> (Range<String.Index>, AgentMath)? in
                guard let range = value.range(of: token, range: index..<value.endIndex) else {
                    return nil
                }
                return (range, math)
            }
            guard let next = matches.min(by: { $0.0.lowerBound < $1.0.lowerBound }) else {
                output += rawRuns(
                    in: String(value[index...]),
                    traits: traits,
                    destination: destination
                )
                break
            }
            if index < next.0.lowerBound {
                output += rawRuns(
                    in: String(value[index..<next.0.lowerBound]),
                    traits: traits,
                    destination: destination
                )
            }
            output.append(.init(
                text: next.1.latex,
                traits: traits,
                destination: destination,
                math: next.1
            ))
            index = next.0.upperBound
        }
        return output
    }

    private static func rawRuns(
        in value: String,
        traits: AgentMarkdownTraits = [],
        destination: URL? = nil
    ) -> [AgentMarkdownRun] {
        guard !value.isEmpty else { return [] }
        guard !traits.contains(.code) else {
            return [.init(text: value, traits: traits, destination: destination)]
        }

        var output: [AgentMarkdownRun] = []
        var literal = ""
        var index = value.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            output.append(.init(text: literal, traits: traits, destination: destination))
            literal.removeAll(keepingCapacity: true)
        }

        while index < value.endIndex {
            guard let delimiter = delimiter(at: index, in: value),
                  let match = match(for: delimiter, from: index, in: value)
            else {
                literal.append(value[index])
                index = value.index(after: index)
                continue
            }

            flushLiteral()
            let math = compatibleMath(latex: match.latex, display: delimiter.display)
            output.append(.init(
                text: math.latex,
                traits: traits,
                destination: destination,
                math: math
            ))
            index = match.endIndex
        }

        flushLiteral()
        return output
    }

    static func prepare(_ value: String) -> PreparedMarkdown {
        var output = ""
        var placeholders: [String: AgentMath] = [:]
        var index = value.startIndex
        var isAtLineStart = true
        var fence: Fence?
        var inlineBacktickCount = 0

        while index < value.endIndex {
            if isAtLineStart, inlineBacktickCount == 0 {
                let line = lineRange(from: index, in: value)
                if let marker = fenceMarker(in: value[line.content]) {
                    let closesFence = fence.map {
                        $0.character == marker.character && marker.count >= $0.count
                    } ?? false
                    if fence == nil || closesFence {
                        output += value[line.complete]
                        fence = closesFence ? nil : marker
                        index = line.complete.upperBound
                        isAtLineStart = true
                        continue
                    }
                }
                if fence != nil {
                    output += value[line.complete]
                    index = line.complete.upperBound
                    isAtLineStart = true
                    continue
                }
            }

            let character = value[index]
            if character == "`" {
                let count = repeatedCharacterCount("`", at: index, in: value)
                let end = value.index(index, offsetBy: count)
                output += value[index..<end]
                if inlineBacktickCount == 0 {
                    inlineBacktickCount = count
                } else if inlineBacktickCount == count {
                    inlineBacktickCount = 0
                }
                index = end
                isAtLineStart = false
                continue
            }

            if inlineBacktickCount == 0,
               let delimiter = delimiter(at: index, in: value) {
                if let match = match(for: delimiter, from: index, in: value) {
                    var token = "KUBECODEMATHTOKEN\(placeholders.count)END"
                    while value.contains(token) || placeholders[token] != nil { token += "X" }
                    let math = compatibleMath(latex: match.latex, display: delimiter.display)
                    placeholders[token] = math
                    output += token
                    index = match.endIndex
                    isAtLineStart = false
                    continue
                }
                if delimiter.opening.first == "\\" {
                    output += delimiter.opening.replacingOccurrences(of: #"\"#, with: #"\\"#)
                    index = value.index(index, offsetBy: delimiter.opening.count)
                    isAtLineStart = false
                } else {
                    output.append(character)
                    index = value.index(after: index)
                    isAtLineStart = character == "\n"
                }
                continue
            }

            output.append(character)
            index = value.index(after: index)
            isAtLineStart = character == "\n"
        }

        return PreparedMarkdown(markdown: output, mathPlaceholders: placeholders)
    }

    private struct Fence {
        let character: Character
        let count: Int
    }

    private struct SourceLine {
        let content: Range<String.Index>
        let complete: Range<String.Index>
    }

    private static func lineRange(from start: String.Index, in value: String) -> SourceLine {
        guard let newline = value[start...].firstIndex(of: "\n") else {
            return .init(content: start..<value.endIndex, complete: start..<value.endIndex)
        }
        return .init(
            content: start..<newline,
            complete: start..<value.index(after: newline)
        )
    }

    private static func fenceMarker(in line: Substring) -> Fence? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }
        guard indentation <= 3, index < line.endIndex,
              line[index] == "`" || line[index] == "~"
        else { return nil }
        let character = line[index]
        var count = 0
        while index < line.endIndex, line[index] == character {
            count += 1
            index = line.index(after: index)
        }
        return count >= 3 ? .init(character: character, count: count) : nil
    }

    private static func repeatedCharacterCount(
        _ character: Character,
        at start: String.Index,
        in value: String
    ) -> Int {
        var index = start
        var count = 0
        while index < value.endIndex, value[index] == character {
            count += 1
            index = value.index(after: index)
        }
        return count
    }

    private static func compatibleMath(latex: String, display: Bool) -> AgentMath {
        let boxedContents = outerBoxContents(in: latex)
        let body = boxedContents ?? latex
        let compatible = body
            .replacingOccurrences(of: #"\operatorname*{"#, with: #"\mathrm{"#)
            .replacingOccurrences(of: #"\operatorname{"#, with: #"\mathrm{"#)
        return .init(
            latex: compatible,
            sourceLatex: latex,
            display: display,
            boxed: boxedContents != nil
        )
    }

    private static func outerBoxContents(in latex: String) -> String? {
        let value = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"\boxed{"#
        guard value.hasPrefix(prefix) else { return nil }
        let openingBrace = value.index(value.startIndex, offsetBy: prefix.count - 1)
        var index = value.index(after: openingBrace)
        var depth = 1
        var escaped = false
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let remainder = value[value.index(after: index)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard remainder.isEmpty else { return nil }
                    return String(value[value.index(after: openingBrace)..<index])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private struct Delimiter {
        let opening: String
        let closing: String
        let display: Bool
        let singleDollar: Bool
    }

    private struct Match {
        let latex: String
        let endIndex: String.Index
    }

    private static func delimiter(at index: String.Index, in value: String) -> Delimiter? {
        if value[index...].hasPrefix("$$") {
            return .init(opening: "$$", closing: "$$", display: true, singleDollar: false)
        }
        if value[index...].hasPrefix(#"\["#) {
            return .init(opening: #"\["#, closing: #"\]"#, display: true, singleDollar: false)
        }
        if value[index...].hasPrefix(#"\("#) {
            return .init(opening: #"\("#, closing: #"\)"#, display: false, singleDollar: false)
        }
        if value[index] == "$" {
            let next = value.index(after: index)
            if next < value.endIndex, value[next].isNumber { return nil }
            return .init(opening: "$", closing: "$", display: false, singleDollar: true)
        }
        return nil
    }

    private static func match(
        for delimiter: Delimiter,
        from openingIndex: String.Index,
        in value: String
    ) -> Match? {
        let contentStart = value.index(openingIndex, offsetBy: delimiter.opening.count)
        guard contentStart < value.endIndex,
              let closingRange = value.range(
                of: delimiter.closing,
                range: contentStart..<value.endIndex
              )
        else { return nil }

        let content = String(value[contentStart..<closingRange.lowerBound])
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if delimiter.singleDollar,
           content.contains("\n")
            || content.first?.isWhitespace == true
            || content.last?.isWhitespace == true {
            return nil
        }
        return Match(
            latex: delimiter.singleDollar ? content : trimmed,
            endIndex: closingRange.upperBound
        )
    }
}

private extension AgentMarkdownBlock {
    var inlineMath: [AgentMath] {
        inlineRuns.compactMap(\.math)
    }

    var inlineRuns: [AgentMarkdownRun] {
        switch self {
        case let .paragraph(runs), let .heading(_, runs):
            runs
        case let .blockQuote(blocks):
            blocks.flatMap(\.inlineRuns)
        case let .unorderedList(items), let .orderedList(_, items):
            items.flatMap { $0.flatMap(\.inlineRuns) }
        case let .table(headers, rows):
            headers.flatMap { $0 } + rows.flatMap { $0.flatMap { $0 } }
        case .codeBlock, .thematicBreak:
            []
        }
    }

    var plainText: String {
        switch self {
        case let .paragraph(runs), let .heading(_, runs):
            runs.map(\.text).joined()
        case let .codeBlock(_, code):
            code
        case let .blockQuote(blocks):
            blocks.map(\.plainText).joined(separator: "\n")
        case let .unorderedList(items), let .orderedList(_, items):
            items.map { $0.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .thematicBreak:
            ""
        case let .table(headers, rows):
            ([headers] + rows).map { row in
                row.map { $0.map(\.text).joined() }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }
}
