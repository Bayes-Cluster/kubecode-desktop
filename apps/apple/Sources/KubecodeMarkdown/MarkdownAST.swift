import Foundation

public struct MarkdownSourcePosition: Equatable, Hashable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct MarkdownSourceRange: Equatable, Hashable, Sendable {
    public let start: MarkdownSourcePosition
    public let end: MarkdownSourcePosition

    public init(start: MarkdownSourcePosition, end: MarkdownSourcePosition) {
        self.start = start
        self.end = end
    }
}

public struct MarkdownTextTraits: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let strong = Self(rawValue: 1 << 0)
    public static let emphasis = Self(rawValue: 1 << 1)
    public static let strikethrough = Self(rawValue: 1 << 2)
}

public struct MarkdownMath: Equatable, Hashable, Sendable {
    public let renderSource: String
    public let source: String
    public let display: Bool
    public let boxed: Bool

    public init(
        renderSource: String,
        source: String,
        display: Bool,
        boxed: Bool = false
    ) {
        self.renderSource = renderSource
        self.source = source
        self.display = display
        self.boxed = boxed
    }
}

public struct MarkdownInline: Identifiable, Equatable, Sendable {
    public indirect enum Kind: Equatable, Sendable {
        case text(String, MarkdownTextTraits)
        case code(String)
        case math(MarkdownMath)
        case link(destination: String?, title: String?, children: [MarkdownInline])
        case image(source: String?, title: String?, alt: String)
        case softBreak
        case lineBreak
        case rawHTML(String)
    }

    public let id: String
    public let sourceRange: MarkdownSourceRange?
    public let kind: Kind

    public init(id: String, sourceRange: MarkdownSourceRange? = nil, kind: Kind) {
        self.id = id
        self.sourceRange = sourceRange
        self.kind = kind
    }

    public var plainText: String {
        switch kind {
        case let .text(value, _), let .code(value), let .rawHTML(value): value
        case let .math(math): math.source
        case let .link(_, _, children): children.map(\.plainText).joined()
        case let .image(_, _, alt): alt
        case .softBreak, .lineBreak: "\n"
        }
    }
}

public enum MarkdownCheckbox: Equatable, Hashable, Sendable {
    case checked
    case unchecked
}

public struct MarkdownListItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let checkbox: MarkdownCheckbox?
    public let blocks: [MarkdownBlock]

    public init(id: String, checkbox: MarkdownCheckbox?, blocks: [MarkdownBlock]) {
        self.id = id
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

public struct MarkdownTable: Equatable, Sendable {
    public enum ColumnAlignment: Equatable, Sendable {
        case left
        case center
        case right
        case unspecified
    }

    public let columnAlignments: [ColumnAlignment]
    public let headers: [[MarkdownInline]]
    public let rows: [[[MarkdownInline]]]

    public init(
        columnAlignments: [ColumnAlignment],
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    ) {
        self.columnAlignments = columnAlignments
        self.headers = headers
        self.rows = rows
    }
}

public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public indirect enum Kind: Equatable, Sendable {
        case paragraph([MarkdownInline])
        case heading(level: Int, [MarkdownInline])
        case codeBlock(language: String?, code: String)
        case blockQuote([MarkdownBlock])
        case unorderedList(items: [MarkdownListItem])
        case orderedList(start: Int, items: [MarkdownListItem])
        case thematicBreak
        case table(MarkdownTable)
        case rawHTML(String)
    }

    public let id: String
    public let sourceRange: MarkdownSourceRange?
    public let kind: Kind

    public init(id: String, sourceRange: MarkdownSourceRange? = nil, kind: Kind) {
        self.id = id
        self.sourceRange = sourceRange
        self.kind = kind
    }

    public var inlineContent: [MarkdownInline] {
        switch kind {
        case let .paragraph(content), let .heading(_, content): content.flatMap(\.flattened)
        case let .blockQuote(blocks): blocks.flatMap(\.inlineContent)
        case let .unorderedList(items), let .orderedList(_, items):
            items.flatMap { $0.blocks.flatMap(\.inlineContent) }
        case let .table(table):
            (table.headers + table.rows.flatMap { $0 }).flatMap { $0.flatMap(\.flattened) }
        case .codeBlock, .thematicBreak, .rawHTML: []
        }
    }

    public var plainText: String {
        switch kind {
        case let .paragraph(content), let .heading(_, content): content.map(\.plainText).joined()
        case let .codeBlock(_, code), let .rawHTML(code): code
        case let .blockQuote(blocks): blocks.map(\.plainText).joined(separator: "\n")
        case let .unorderedList(items), let .orderedList(_, items):
            items.map { $0.blocks.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .thematicBreak: ""
        case let .table(table):
            ([table.headers] + table.rows).map { row in
                row.map { $0.map(\.plainText).joined() }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }
}

public struct KubecodeMarkdownDocument: Equatable, Sendable {
    public let source: String
    public let blocks: [MarkdownBlock]

    public init(source: String, blocks: [MarkdownBlock]) {
        self.source = source
        self.blocks = blocks
    }

    public var inlineContent: [MarkdownInline] {
        blocks.flatMap(\.inlineContent)
    }

    public var math: [MarkdownMath] {
        inlineContent.compactMap { inline in
            guard case let .math(value) = inline.kind else { return nil }
            return value
        }
    }

    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }
}

private extension MarkdownInline {
    var flattened: [MarkdownInline] {
        switch kind {
        case let .link(_, _, children): [self] + children.flatMap(\.flattened)
        default: [self]
        }
    }
}
