import Foundation
import KubecodeMarkdown

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

    init(_ value: MarkdownMath) {
        self.init(
            latex: value.renderSource,
            sourceLatex: value.source,
            display: value.display,
            boxed: value.boxed
        )
    }
}

struct AgentMarkdownTraits: OptionSet, Equatable, Hashable, Sendable {
    let rawValue: Int

    static let strong = Self(rawValue: 1 << 0)
    static let emphasis = Self(rawValue: 1 << 1)
    static let strikethrough = Self(rawValue: 1 << 2)
    static let code = Self(rawValue: 1 << 3)
}

struct AgentMarkdownImage: Equatable, Sendable {
    let source: String?
    let title: String?
    let alt: String
}

struct AgentMarkdownImageLoad: Equatable, Sendable {
    let source: String
    let remoteURL: URL?
    let projectPath: String?
}

struct AgentMarkdownRun: Equatable, Sendable {
    let text: String
    let traits: AgentMarkdownTraits
    let destination: URL?
    let math: AgentMath?
    let image: AgentMarkdownImage?

    init(
        text: String,
        traits: AgentMarkdownTraits = [],
        destination: URL? = nil,
        math: AgentMath? = nil,
        image: AgentMarkdownImage? = nil
    ) {
        self.text = text
        self.traits = traits
        self.destination = destination
        self.math = math
        self.image = image
    }
}

enum AgentMarkdownTableAlignment: Equatable, Sendable {
    case left
    case center
    case right
    case unspecified
}

struct AgentMarkdownListItem: Equatable, Sendable {
    let checkbox: MarkdownCheckbox?
    let blocks: [AgentMarkdownBlock]
}

indirect enum AgentMarkdownBlock: Equatable, Sendable {
    case paragraph([AgentMarkdownRun])
    case heading(level: Int, [AgentMarkdownRun])
    case codeBlock(language: String?, code: String)
    case blockQuote([AgentMarkdownBlock])
    case unorderedList(items: [AgentMarkdownListItem])
    case orderedList(start: Int, items: [AgentMarkdownListItem])
    case thematicBreak
    case table(
        alignments: [AgentMarkdownTableAlignment],
        headers: [[AgentMarkdownRun]],
        rows: [[[AgentMarkdownRun]]]
    )
    case rawHTML(String)
}

struct AgentMarkdownDocument: Equatable, Sendable {
    let blocks: [AgentMarkdownBlock]

    init(source: String) {
        blocks = MarkdownParser.parse(source).blocks.map(Self.project)
    }

    var inlineMath: [AgentMath] {
        blocks.flatMap(\.inlineRuns).compactMap(\.math)
    }

    var inlineRuns: [AgentMarkdownRun] {
        blocks.flatMap(\.inlineRuns)
    }

    var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    var imageLoads: [AgentMarkdownImageLoad] {
        var seen = Set<String>()
        return inlineRuns.compactMap(\.image).compactMap { image in
            guard let source = image.source, seen.insert(source).inserted
            else { return nil }
            let remoteURL = MarkdownResourcePolicy.remoteImageURL(source)
            let projectPath = remoteURL == nil
                ? MarkdownResourcePolicy.projectRelativeImagePath(source)
                : nil
            guard remoteURL != nil || projectPath != nil else { return nil }
            return .init(source: source, remoteURL: remoteURL, projectPath: projectPath)
        }
    }

    private static func project(_ block: MarkdownBlock) -> AgentMarkdownBlock {
        switch block.kind {
        case let .paragraph(content): .paragraph(project(content))
        case let .heading(level, content): .heading(level: level, project(content))
        case let .codeBlock(language, code): .codeBlock(language: language, code: code)
        case let .blockQuote(blocks): .blockQuote(blocks.map(project))
        case let .unorderedList(items):
            .unorderedList(items: items.map { item in
                .init(checkbox: item.checkbox, blocks: item.blocks.map(project))
            })
        case let .orderedList(start, items):
            .orderedList(start: start, items: items.map { item in
                .init(checkbox: item.checkbox, blocks: item.blocks.map(project))
            })
        case .thematicBreak: .thematicBreak
        case let .table(table):
            .table(
                alignments: table.columnAlignments.map { alignment in
                    switch alignment {
                    case .left: .left
                    case .center: .center
                    case .right: .right
                    case .unspecified: .unspecified
                    }
                },
                headers: table.headers.map(project),
                rows: table.rows.map { $0.map(project) }
            )
        case let .rawHTML(value): .rawHTML(value)
        }
    }

    private static func project(_ content: [MarkdownInline]) -> [AgentMarkdownRun] {
        content.flatMap { inline -> [AgentMarkdownRun] in
            switch inline.kind {
            case let .text(value, traits):
                return [.init(text: value, traits: project(traits))]
            case let .code(value):
                return [.init(text: value, traits: [.code])]
            case let .math(value):
                return [.init(text: value.renderSource, math: .init(value))]
            case let .link(destination, _, children):
                let url = safeDestination(destination)
                return project(children).map { run in
                    .init(
                        text: run.text,
                        traits: run.traits,
                        destination: url,
                        math: run.math,
                        image: run.image
                    )
                }
            case let .image(source, title, alt):
                return [.init(
                    text: alt,
                    image: .init(source: source, title: title, alt: alt)
                )]
            case .softBreak:
                return [.init(text: " ")]
            case .lineBreak:
                return [.init(text: "\n")]
            case let .rawHTML(value):
                return [.init(text: value, traits: [.code])]
            }
        }
    }

    private static func project(_ traits: MarkdownTextTraits) -> AgentMarkdownTraits {
        var result: AgentMarkdownTraits = []
        if traits.contains(.strong) { result.insert(.strong) }
        if traits.contains(.emphasis) { result.insert(.emphasis) }
        if traits.contains(.strikethrough) { result.insert(.strikethrough) }
        return result
    }

    private static func safeDestination(_ destination: String?) -> URL? {
        guard let destination,
              let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return url
    }
}

private extension AgentMarkdownBlock {
    var inlineRuns: [AgentMarkdownRun] {
        switch self {
        case let .paragraph(runs), let .heading(_, runs): runs
        case let .blockQuote(blocks): blocks.flatMap(\.inlineRuns)
        case let .unorderedList(items), let .orderedList(_, items):
            items.flatMap { $0.blocks.flatMap(\.inlineRuns) }
        case let .table(_, headers, rows):
            headers.flatMap { $0 } + rows.flatMap { $0.flatMap { $0 } }
        case .codeBlock, .thematicBreak, .rawHTML: []
        }
    }

    var plainText: String {
        switch self {
        case let .paragraph(runs), let .heading(_, runs): runs.map(\.text).joined()
        case let .codeBlock(_, code), let .rawHTML(code): code
        case let .blockQuote(blocks): blocks.map(\.plainText).joined(separator: "\n")
        case let .unorderedList(items), let .orderedList(_, items):
            items.map { $0.blocks.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .thematicBreak: ""
        case let .table(_, headers, rows):
            ([headers] + rows).map { row in
                row.map { $0.map(\.text).joined() }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }
}
